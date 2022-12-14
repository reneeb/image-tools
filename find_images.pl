#!/usr/bin/perl

use v5.24;

use DBI;
use Digest::SHA 'sha256_hex';
use File::Basename;
use File::Find::Rule;
use Getopt::Long;
use Image::ExifTool ':Public';
use Mojo::Collection 'c';
use Mojo::File 'path';

use experimental 'signatures';

our $VERSION = '1.0.1';

GetOptions(
    'path=s'      => \my $path,
    'db=s'        => \my $db,
    'mime-type=s' => \my $mime_type,
);

$mime_type //= 'image/';
$db        //= './images.db';
$path      //= '.';

_db( $db );

my $image_infos = _collect_images ( $path, $mime_type );
_add_to_db( $image_infos, $db );

use Data::Printer;
p $image_infos;


=head1 _collect_images

=cut 

sub _collect_images( $path, $mime_type ) {
    my $rule = File::Find::Rule->new
        # collect only files, not directories
        ->file
        # collect only files with specific mime types
        ->exec(
            sub {
                my $file_output = qx{file -i $_};
                my $mimetype = do {
                    my $mt = reverse( (split /:/, reverse $file_output)[0] );
                    (split /;/, $mt)[0];
                };
                $mimetype =~ qr{\Q$mime_type\E}i;
            }
        );

    my $files = c( $rule->in( $path ) );

    my $image_counter = 0;

    my %info;
    $files->each( sub {
        say "process $_...";
        $image_counter++;

        my $image_info = _get_image_info( $_ );

        for my $key ( qw/Latitude Longitude Position/ ) {
            $image_info->{$key . 'Dec'} = $image_info->{'GPS' . $key} =~ s{
                (?<degree>[0-9]+) \s+ deg \s+          # degrees
                (?<minutes>[0-9]+) ' \s*               # minutes
                (?<seconds>[0-9]+(?:\.[0-9]+)) " \s+   # seconds
                (?<direction>N|E|S|W)                  # direction
            }{
                ( ( $+{direction} eq 'S' or $+{direction} eq 'W' ) ? '-' : '' ) .
                ( $+{degree} + ( $+{minutes} / 60 ) + ( $+{seconds} / 3600 ) )
            }xsmegr;
        }

        my $original_date;
        if ( $image_info->{CreateDate} ) {
            $original_date = $image_info->{CreateDate};

            if ( $image_info->{OffsetTimeOriginal} && $original_date !~ m{[+-]}) {
                $original_date .= $image_info->{OffsetTimeOriginal};
            }
        }

        my $created_orig =
            $original_date // $image_info->{SubSecDateTimeOriginal} //
            $image_info->{SubSecCreateDate} // $image_info->{DateTimeOriginal} //
            $image_info->{TimeStamp} // $image_info->{MediaCreateDate} //
            $image_info->{TrackCreateDate} // $image_info->{FileModifyDate};


        $info{$_} = {
            Latitude     => $image_info->{GPSLatitude},
            Longitude    => $image_info->{GPSLongitude},
            LatitudeDec  => $image_info->{LatitudeDec},
            LongitudeDec => $image_info->{LongitudeDec},
            GPSTime      => $image_info->{GPSDateTime},
            Position     => $image_info->{GPSPosition},
            PositionDec  => $image_info->{PositionDec},
            Model        => $image_info->{Model},
            Vendor       => $image_info->{Make},
            Path         => $_,
            CreatedInode => $image_info->{FileInodeChangeDate},
            CreatedOrig  => $created_orig,
            SHA256       => $image_info->{SHA256},
        };
    });

    say "processed $image_counter images...";

    return \%info;
}

=head1 _get_image_info

Collect all the information about an image. Returns a hashref
with all available data. Which data is available depends on
the type of image. E.g. for some photos GPS information might
be available.

  my $info_hash = _get_image_info( $full_path_to_image );

=cut

sub _get_image_info ( $filepath ) {
    my $info = ImageInfo( $filepath );

    my $sha256 = sha256_hex( path( $filepath )->slurp );
    $info->{SHA256} = $sha256;

    for my $timestamp_key ( qw/
        TimeStamp FileInodeChangeDate GPSDateTime TrackCreateDate MediaCreateDate
        FileModifyDate SubSecDateTimeOriginal SubSecCreateDate CreateDate DateTimeOriginal
    /) {
        if ( $info->{$timestamp_key} ) {
            my ($date, $time) = split / /, $info->{$timestamp_key}, 2;
            $date =~ s{:}{-}g;
            $time =~ s{\.\d+}{}g;

            $info->{$timestamp_key} = join ' ', $date, $time;
        }
    }

    return $info;
}

=head1 _add_to_db

Add the image information to the database. It doesn't check for duplicates,
that's the database's task.

  _add_to_db( $hash_ref_with_image_information, $path_to_database_file );

=cut

sub _add_to_db ( $images, $db ) {
    say "Add images to database...";

    my $dbh = _db( $db );

    my $insert = q~
        INSERT INTO image_data (
            filename, path, sha256, model, vendor, create_inode, create_orig,
            gps_position, gps_latitude, gps_longitude, gps_time,
            gps_position_dec, gps_latitude_dec, gps_longitude_dec
        ) VALUES (
            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        )
    ~;

    my $sth = $dbh->prepare( $insert );

    my $insert_counter = 0;

    for my $path ( sort keys $images->%* ) {
        $sth->execute(
            basename( $path ),
            $images->{$path}->@{qw/
                Path SHA256 Model Vendor CreatedInode CreatedOrig
                Position Latitude Longitude GPSTime
                PositionDec LatitudeDec LongitudeDec
            /},
        );

        $insert_counter++;
        say "$insert_counter..." if !( $insert_counter % 100 );
    }
}

=head1 _db

Establish connection to SQLite database. If it doesn't exist yet,
create the database and create the table that stores the image
information

  my $dbh = _db( $path_to_database_file );

The table columns:

=over 4

=item * filename

=item * path (PRIMARY KEY)

=item * sha256

=item * model (of the device that was used to take the photo)

=item * vendor (of the mentioned device)

=item * create_inode

=item * create_orig

=item * gps_position (GPS position, lat/lon combined)

=item * gps_latitude (GPS position -- latitude)

=item * gps_longitude (GPS position -- longitude)

=item * gps_position_dec (GPS position, lat/lon combined - decimal format)

=item * gps_latitude_dec (GPS position -- latitude - decimal format)

=item * gps_longitude_dec (GPS position -- longitude - decimal format)

=item * gps_time

=back

=cut

sub _db ( $db ) {
    my $create_db;
    if ( !-f $db ) {
        $create_db++;
    }

    my $dbh = DBI->connect( 'DBI:SQLite:' . $db );

    my $table_sql = qq~
        CREATE TABLE image_data (
            filename          VARCHAR(250) NOT NULL,
            path              VARCHAR(800) NOT NULL,
            sha256            VARCHAR(250),
            model             VARCHAR(250),
            vendor            VARCHAR(250),
            create_inode      DATETIME,
            create_orig       DATETIME,
            gps_position      VARCHAR(50),
            gps_latitude      VARCHAR(50),
            gps_longitude     VARCHAR(50),
            gps_position_dec  VARCHAR(50),
            gps_latitude_dec  VARCHAR(50),
            gps_longitude_dec VARCHAR(50),
            gps_time          VARCHAR(50),
            PRIMARY KEY( path )
        )
    ~;

    if ( $create_db ) {
        $dbh->do( $table_sql );
    }

    return $dbh;
}

#! /usr/bin/env perl

use v5.36;

use Archive::SCS;
use Archive::SCS::GameDir;
use Archive::SCS::InMemory;
use Archive::SCS::Zip;
use Data::SCS::DefParser 0.11;
use Getopt::Long 2.33 qw( GetOptions :config gnu_getopt no_bundling no_ignore_case );
use IO::Compress::Zip qw( :constants );
use List::Util 1.45 qw( any none min uniqstr );
use Pod::Usage qw( pod2usage );
use Path::Tiny 0.125;
use YAML::Tiny;

my $MOD_SLUG = 'Show_company_branches';

my %options = (
  branch_desc => 'branch_desc.yaml',
  branch_id   => 'branch_id.yaml',
  companies   => 'company.yaml',
  description => 'description.txt',
  game        => 'ATS',
  mod_author  => 'nautofon',
  thumbnail   => 'thumbnail.jpg',
);
GetOptions(
  'branches=s'    => \$options{branch_desc},
  'companies|c=s' => \$options{companies},
  'compress'      => \$options{compress},
  'description=s' => \$options{description},
  'game=s'        => \$options{game},
  'help|man|?'    => \$options{man},
  'identifiers=s' => \$options{branch_id},
  'mod-author=s'  => \$options{mod_author},
  'mod-version=s' => \$options{mod_version},
  'output=s'      => \$options{output},
  'thumbnail|t=s' => \$options{thumbnail},
) or pod2usage(2);
pod2usage(-exitstatus => 0, -verbose => 2) if $options{man} || @ARGV;



my %files;

sub write_file ( $name, $data, $file_opts = {} ) {
  $files{$name} and die "duplicate file $name";
  $files{$name} = { data => $data, file_opts => $file_opts };
  $files{$name}{file_opts}{zip_opts}{Method} //= ZIP_CM_STORE unless $options{compress};
}



my $ats = Archive::SCS::GameDir->new( game => $options{game} );

my $game_version = $ats->version =~ s/\A( .+? \. .+? )\..*/$1/rx;
my $package_version = $options{mod_version} // $game_version;

chdir path(__FILE__)->parent or die "Can't change dir: $!";
path( $options{output} //= 'v' . $ats->version )->mkdir;

write_file 'manifest.sii', <<END, { order => chr 0 };
SiiNunit
{
mod_package : .branch_names {
	package_version: "$package_version"
	display_name: "Show company branches v$package_version"
	author: "$options{mod_author}"
	category[]: "ui"
	icon: "thumbnail.jpg"
	description_file: "description.txt"
	mp_mod_optional: true
}
}
END

my $mod_description = path($options{description})->slurp_utf8 =~ s/(\$\w+)/ eval $1 /aegr;
write_file 'description.txt', $mod_description, { order => chr 1 };

if (length $options{thumbnail}) {
  my $thumbnail = path($options{thumbnail})->slurp_raw;
  $thumbnail =~ m/^\xff\xd8(?:\xff\xe0..JFIF|\xff\xe1..Exif)/ or die "Thumbnail is not a JPEG file";
  # requires exact size: 276x162px
  write_file 'thumbnail.jpg', $thumbnail, {
    zip_opts => { Time => path($options{thumbnail})->stat->mtime },
  };
}



# Some company defs are kept in the DLCs (especially in ATS 1.54 and earlier).
# We need to know about those because they need a different file path in the mod.
my %DLC;
my $dlc_mounted = $ats->mounted( grep m'^dlc_', $ats->archives );
for ( grep m'^def/company\.dlc_', $dlc_mounted->list_files ) {
  for ( split m'\n', $dlc_mounted->read_entry($_) ) {
    $DLC{$1} = $2 if m'^@include "company/(.+?)\.(dlc_.+?)\.sui"';
  }
}

my $parser = Data::SCS::DefParser->new( mount => $options{game} );
my $data = $parser->data;

my %companies = eval { YAML::Tiny->read( $options{companies} )->[0]->%* };

if ( ! %companies ) {
  # If no company file is available, we can try to generate equivalent data
  # by looking at which branches share a logo texture in the UI.
  my $base = $ats->mounted('base.scs');
  for my $branch ( sort keys $data->{company}{permanent}->%* ) {
    my $company = eval {
      my $logo = $base->read_entry("material/ui/company/small/$branch.mat");
      $logo =~ m/source *: *"(.+?)\.tobj"/ and $1
    } // 'fallback';
    push $companies{$company}{branches}->@*, $branch;
    $companies{$company}{name} = $data->{company}{permanent}{$branch}{name};
  }
  # Fix overlong names
  $companies{jns}{name}    = 'Johnson & Smith';
  $companies{taylor}{name} = 'Taylor';
}



my @all_locs = $parser->all_locations(\%companies, $data);
my @companies =
  sort { $companies{$a}{name} cmp $companies{$b}{name} }
  sort keys %companies;

COMPANY:
for my $company (@companies) {
  my @branches =
    grep { my $id = $_; any { $_->{branch} eq $id } @all_locs }
    $companies{$company}{branches}->@*;
  next COMPANY unless @branches > 1;
  
  # Skip companies that never have two locations in the same city
  # (This could probably be further improved by also skipping *branches*
  # that only ever appear alone in a city.)
  my @company_locs = grep { $_->{company} eq $company } @all_locs;
  my @loc_cities = sort map { $_->{city} } @company_locs;
  my @cities = uniqstr @loc_cities;
  next COMPANY if @loc_cities == @cities;
  
  # Prepare short human-readable branch ids
  my @id_parts_branches = map {[ split '_', $_ ]} @branches;
  my $i = 0;
  ++$i while
    none { $_ ne ($id_parts_branches[0]->[$i] // '') }
    map { $_->[$i] // '' } @id_parts_branches;
  my $id_parts_common = $i;
  state %id_parts_readable = eval { YAML::Tiny->read( $options{branch_id} )->[0]->%* };
  for my $branch (@branches) {
    my @id_parts = split '_', $branch;
    shift @id_parts for 1 .. min( $id_parts_common, $#id_parts );
    $id_parts_readable{$branch} //= join ' ', @id_parts;
  }
  
  # QA: Verify that there is no city with two company locations that
  # share the same human-readable branch id
  for my $city (@cities) {
    my @ids = sort
      map { $id_parts_readable{$_->{branch}} }
      grep { $_->{city} eq $city } @company_locs;
    @ids == uniqstr @ids or die
      sprintf "Duplicate human-readable branch ids for %s in %s",
      $companies{$company}{name} // "'$company'",
      $data->{city}{$city}{city_name};
  }
  
  # Write new def files for all branches of affected companies
  for my $branch (@branches) {
    my $name = $companies{$company}{name};
    $name .= " /" . $id_parts_readable{$branch} . "";
    
    {
      my $dlc = ($DLC{$branch} // '') =~ s/.*(?:^|_)[^_]*?(...?)$/$1/r;
      state %branch_desc = eval { YAML::Tiny->read( $options{branch_desc} )->[0]->%* };
      state $fh = path("$options{output}/company_list.txt")->openw;
      say $fh sprintf '%-12s %3s  %-28s "%s"',
        $branch, $dlc, $name, $branch_desc{$branch} // '';
    }
    
    my %sui = (
      branch_id    => $branch,
      name         => $name,
      sort_name    => lc $name,
      trailer_look => $data->{company}{permanent}{$branch}{trailer_look},
    );
    my @filenames = $branch . '.sui';
    push @filenames, $branch . '.' . $DLC{$branch} . '.sui' if $DLC{$branch};
    for my $filename (@filenames) {
      write_file "def/company/$filename", <<~END;
      company_permanent: company.permanent.$sui{branch_id}
      {
        name: "$sui{name}"
        sort_name: "$sui{sort_name}"
        trailer_look: $sui{trailer_look}
      }
      END
    }
  }
}

my %dirs = Archive::SCS::DirIndex->auto_index([ keys %files ])->%*;

my $scs = Archive::SCS->new;
my $mem = Archive::SCS::InMemory->new;
$mem->add_entry($_, $files{$_}{data}) for keys %files;
$mem->add_entry($_, $dirs{$_}) for keys %dirs;
$scs->mount($mem);

my $file = "$options{output}/$MOD_SLUG.scs";
my %file_opts = map {( $_ => $files{$_}{file_opts} )} keys %files;

Archive::SCS::Zip::create_file($file, $scs, \%file_opts);

say "Created mod file: $file";



__END__

=head1 SYNOPSIS

 Show_company_branches.pl
 Show_company_branches.pl --help

=head1 DESCRIPTION

Generates the B<Show company branches> mod file for ATS.

The mod changes the names of certain in-game companies to add an
identifier for the company branch. Specifically, it does so for those
companies that actually I<have> two separate locations in the same
city somewhere; all other companies are not affected by this mod.

This script creates a C<company_list.txt> file in addition to the
generated mod file. It's good practice to diff that text file
against that of an earlier version, so you can check the output for
obvious errors or any other unexpected changes.

=head1 OPTIONS

All file and directory paths are interpreted relative to the
directory this script is in.

=over

=item --branches

Path to a L<YAML::Tiny> file with human-readable branch descriptions.
Defaults to C<branch_desc.yaml>.

=item --companies, -c

Path to a L<YAML::Tiny> file with company/branch associations and
company names. Defaults to C<company.yaml>.
The data format looks like this:

  company_id:  # The ID doesn't matter, as long as it's unique
    branches:
      - game_token_1  # e.g. frd_epw_sit
      - game_token_2  # e.g. frd_epw_svc
    name: Company Name

If this file is present, it must contain I<all> branch tokens
in the game. If it is not present or unreadable, data read
automatically from C<base.scs> will be used instead.

=item --compress

Enable ZIP compression for the generated mod file. Disabled by
default because compression saves next to nothing here.

=item --description

Path to the mod description template file.
Defaults to C<description.txt>.

=item --game

Control the data source, typically a game name or the path to
a game install directory. This option is passed on to
L<Archive::SCS::GameDir/"find">. Defaults to C<ATS>.

=item --help, -?

Display this manual page.

=item --identifiers

Path to a L<YAML::Tiny> file with human-readable branch identifiers.
Defaults to C<branch_id.yaml>.

=item --mod-author

Set author name to be written into the mod manifest.
Defaults to C<nautofon>.

=item --mod-version

Set version number to be written into the mod manifest. Defaults
to the two most significant parts of the installed game's version
number (something like C<1.49>).

This option is meant for cases where multiple mod versions are
released for the same game version. The suggested numbering scheme
is C<1.49-beta>, C<1.49>, C<1.49-2> etc.

=item --output

Path to the directory in which to create the mod file and company
list. Existing files will be overwritten. Defaults to the installed
game's version number (something like C<v1.49.0.99>).

=item --thumbnail, -t

Path to the mod thumbnail in JPEG format. Note that the game
may require mod thumbnails to have a specific size.
Defaults to C<thumbnail.jpg>.

=back

=head1 LIMITATIONS

=over

=item *

This mod artificially inflates the company count on the Career
view. The statistics for visited companies will be mostly
meaningless while this mod is active.
It looks like disabling the mod will bring back the correct
numbers, but this is not yet well tested.

It also affects the Logistics Map. Basically, while this mod is
active, some branches of certain companies will appear as a
separate company each.

=item *

This mod only adds the branch identifier to companies that
actually I<have> 2+ locations in at least one city.

Even then, separate company branches that are never ambiguous
for an arriving driver may share the same branch identifier
in order to keep the displayed name as short as possible.

=item *

Some combinations of city name, company name and branch identifier
are too long to fit comfortably in the Route Advisor's destination
field. In these cases, the city name will overflow the field and
will be rendered on top of the field label, which may make the
city name difficult to read. The full job info is always clearly
displayed in the Driver Manager.

For an example of the issue, see L<this screenshot|https://raw.githubusercontent.com/nautofon/Show_company_branches/release/images/branch-names-combo-too-long.png>.

=item *

The game only ever shows the name of a company for a job after
you've accepted it. So this mod can't help you with navigating
to the I<start> of a job in the offline freight/cargo market.
For external WoT jobs, the start location may be identified
via the Driver Manager.

=back

=head1 SEE ALSO

L<https://github.com/nautofon/Show_company_branches>

L<https://forum.scssoft.com/viewtopic.php?t=326360>

=head1 AUTHOR

L<nautofon|https://github.com/nautofon>

=head1 COPYRIGHT

This software is copyright (c) 2025 by nautofon.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

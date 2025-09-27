#! /usr/bin/env perl

use v5.36;

use Archive::SCS;
use Archive::SCS::GameDir;
use Archive::SCS::InMemory;
use Archive::SCS::Zip;
use Data::SCS::DefParser 0.11;
use Getopt::Long 2.33 qw( :config posix_default gnu_getopt auto_version auto_help );
use IO::Compress::Zip qw( :constants );
use List::Util 1.45 qw( any none min uniqstr );
use Pod::Usage qw( pod2usage );
use Path::Tiny 0.125;
use YAML::Tiny;

my $MODS_DIR = '~/Library/Application Support/American Truck Simulator/mod';
my $MOD_SLUG = 'Show_company_branches';

# The branch ID tokens are sometimes not very human-readable.
my %ID_PARTS_READABLE = (
  bn_live_auc  => [qw( auc )],
  cm_brx_pln   => [qw( plnt )],
  cm_min_plnt  => [qw( plnt )],
  cm_min_qry   => [qw( qry )],
  cm_min_qryp  => [qw( qry )],
  cm_min_str   => [qw( str )],
  cm_min_svc   => [qw( svc )],
  dg_wd_saw1   => [qw( saw )],
  gal_oil_str1 => [qw( str )],
  gp_live_auc  => [qw( auc )],
  mon_food_pln => [qw( plnt )],
  nmq_min_pln1 => [qw( plnt )],
  nmq_min_qrya => [qw( qry )],
  nmq_min_qrys => [qw( qry )],
  pns_con_sit  => [qw( cons )],  # generic
  pns_con_sit1 => [qw( cons )],  # basement
  pns_con_sit2 => [qw( hse cons )],
  pns_con_sit3 => [qw( whs cons )],
  tay_con_sit  => [qw( cons )],  # generic
  tay_con_sit1 => [qw( cons )],  # basement
  tay_con_sit2 => [qw( cons )],  # houses
  tay_con_sit3 => [qw( cons )],  # warehouse
  vor_oil_str1 => [qw( str )],
  vor_oil_str  => [qw( term )],
  #wal_food_mkt => [qw( food mkt )],  # problem is, we still have like "food str" for grain silos,
  #wal_food_whs => [qw( food whs )],  # so "fd" just here doesn't really make sense
  wal_mkt      => [qw( nonfd mkt )],
  wal_whs      => [qw( nonfd whs )],
);

# Some company defs are kept in the DLCs, some are not. There doesn't seem
# to be an entirely reliable rule for this, so we need to hard-code it.
# This list frequently changes with major game updates. The current version
# as well as the previous version should be supported.
my %DLC = (
  asu_car_pln  => 'dlc_tx',  # 1.53
  cal_car_exp  => 'dlc_ks',  # 1.53
  cal_car_pln  => 'dlc_ks',  # 1.53
  cm_min_qryp  => 'dlc_ut',
  kw_trk_dlr   => 'dlc_kenworth_t680',
  kw_trk_pln   => 'dlc_kenworth_t680',
  nls_rd_grg   => 'dlc_ne',  # 1.53
  nmq_min_pln1 => 'dlc_mt',
  nmq_min_qrya => 'dlc_wy',
  vor_oil_sit  => 'dlc_tx',  # 1.53
);
# To get an updated list:
# scs_archive --list-files | grep 'def/company\.dlc_' | scs_archive --extract - --output - | grep include | sort | perl -pe "s/\@include \"company\//\t/;s/\.dlc_/ => 'dlc_/;s/\.sui\"/',/"
# But that list should be limited to those companies that actually do
# appear multiple times. To identify these, look at the --verbose output.



my %options = (
  branch_desc => 'branch_desc.yaml',
  game        => 'ATS',
  thumbnail   => '',
);
GetOptions(
  'dir=s' => \$options{dir},
  'man' => \$options{man},
  'replace|r' => \$options{replace},
  'clean' => \$options{clean},
  'thumbnail|t=s' => \$options{thumbnail},
  'game' => \$options{game},
  'mod-version=s' => \$options{mod_version},
  'verbose|v' => \$options{verbose},
  'compatible-versions!' => \$options{compatible_versions},
) or pod2usage(2);
pod2usage(-exitstatus => 0, -verbose => 2) if $options{man};

my $dir;
if (defined $options{dir}) {
  $dir = path($MODS_DIR)->child($MOD_SLUG);
  $dir = path($options{dir}) if length $options{dir};
  die "'$dir' exists; cannot replace"
    if $dir->exists && (! $dir->is_dir || ! -w $dir);
  die "Directory '$dir' exists; use --replace, -r to overwrite"
    if $dir->is_dir && $dir->children && ! $options{replace};
  $dir->remove_tree({ safe => 0, keep_root => 1 })
    if $options{dir} && $options{replace} && $options{clean};
}

my $file = path($MODS_DIR)->child("$MOD_SLUG.scs");
$file = path($ARGV[0]) if @ARGV;
die "'$file' exists; cannot replace"
  if $file->exists && (! -f $file || ! -w $file);
die "File '$file' exists; use --replace, -r to overwrite"
  if $file->exists && ! $options{replace};

my %files;

sub write_file ( $name, $data, $file_opts = {} ) {
  if ($dir) {
    my $subdir = $dir->child($name)->parent;
    $subdir->mkdir unless $subdir->exists;
  }
  $dir->child($name)->spew_raw($data) if $dir;
  
  $files{$name} and die "duplicate file $name";
  $files{$name} = { data => $data, file_opts => $file_opts };
  $files{$name}{file_opts}{zip_opts}{Method} //= ZIP_CM_STORE unless $options{compress};
}



my $ats = Archive::SCS::GameDir->new( game => $options{game} );

my $game_version = $ats->version =~ s/\A( .+? \. .+? )\..*/$1/rx;
my $package_version = $options{mod_version} // $game_version;
my $compatible_versions = [];
if ($options{compatible_versions}) {
  # The argument for setting compatible_versions[] is that it's better to fail
  # loudly than to fail silently. Needs to be mentioned in the forum thread.
  # But let's additionally declare one earlier version and one later version
  # as compatible, so that upgrading the mod is less painful for users.
  push @$compatible_versions, $game_version =~ s{^(.*\.)([0-9]+)$}{ $1 . ($2 - 1) }re;
  push @$compatible_versions, $game_version;
  push @$compatible_versions, $game_version =~ s{^(.*\.)([0-9]+)$}{ $1 . ($2 + 1) }re;
}
$compatible_versions = join "", map {"\tcompatible_versions[]: \"$_.*\"\n"} @$compatible_versions;

write_file 'manifest.sii', <<END, { order => chr 0 };
SiiNunit
{
mod_package : .branch_names {
	package_version: "$package_version"
	display_name: "Show company branches v$package_version"
	author: "nautofon"
	category[]: "ui"
	icon: "thumbnail.jpg"
	description_file: "description.txt"
	mp_mod_optional: true
$compatible_versions}
}
END

write_file 'description.txt', <<END, { order => chr 1 };
[normal]The [orange]Show company branches[normal] mod changes the names of certain in-game companies to add an identifier for the company branch.

For example, where previously all Home Store locations would just be labeled [orange]Home Store[normal], with this mod active, markets and warehouses will instead be labeled [orange]Home Store /mkt[normal] and [orange]Home Store /whs[normal], respectively. This helps players who drive without simulated GPS navigation to more easily find the correct destination in cities that have multiple locations of the same company.

[orange]Limitations:[normal]

The statistics for visited companies in the Career view are modified by this mod. It looks like disabling the mod will bring back the correct numbers, but this is not yet well tested.

Additional limitations exist. Please see the mod's discussion thread on the SCS forum for details. 

[orange]Compatibility:[normal]

This version of the mod is designed primarily for ATS $game_version.

I recommend you update this mod whenever SCS adds new cities to the game. If not updated, the mod should continue to work, but might not always show the correct branch identifiers in those new cities.

[orange]Distribution:[normal]

This mod is placed into the Public Domain. You do whatever you want with it! :) Attribution would be appreciated, but it's not required. To cite the original source of the idea, feel free to credit the author as [orange]nautofon [normal]and/or link to this mod's discussion thread on the SCS forum.

[blue]https://forum.scssoft.com/viewtopic.php?t=326360[normal]

Enjoy!
END

if (length $options{thumbnail}) {
  my $thumbnail = path($options{thumbnail})->slurp_raw;
  $thumbnail =~ m/^\xff\xd8(?:\xff\xe0..JFIF|\xff\xe1..Exif)/ or die "Thumbnail is not a JPEG file";
  # requires exact size: 276x162px
  write_file 'thumbnail.jpg', $thumbnail, {
    zip_opts => { Time => path($options{thumbnail})->stat->mtime },
  };
}



my $parser = Data::SCS::DefParser->new( mount => $options{game} );
my $data = $parser->data;

my %companies = eval { YAML::Tiny->read( path(__FILE__)->sibling('company.yaml') )->[0]->%* };

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
  my %id_parts_readable;
  for my $branch (@branches) {
    my @id_parts = split '_', $branch;
    shift @id_parts for 1 .. min( $id_parts_common, $#id_parts );
    @id_parts = $ID_PARTS_READABLE{$branch}->@* if $ID_PARTS_READABLE{$branch};
    $id_parts_readable{$branch} = join ' ', @id_parts;
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
    
    if ($options{verbose}) {
      my $dlc = ($DLC{$branch} // '') =~ s/.*(?:^|_)[^_]*?(...?)$/$1/r;
      state %branch_desc = eval { YAML::Tiny->read( $options{branch_desc} )->[0]->%* };
      say sprintf '%-12s %3s  %-28s "%s"',
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

my %file_opts = map {( $_ => $files{$_}{file_opts} )} keys %files;

Archive::SCS::Zip::create_file($file, $scs, \%file_opts);



__END__

=head1 SYNOPSIS

 script/mod-show-branches.pl mod.scs --thumbnail image.jpg
 script/mod-show-branches.pl
 script/mod-show-branches.pl --replace
 script/mod-show-branches.pl --dir mod_dir --replace --clean

=head1 DESCRIPTION

Writes the files for the "Show Company Branches" mod. The output-dir argument
is optional; a default location is used if it's not provided (on macOS,
it will use the ATS mod dir).

Note: this mod might influence the progress stats (% of companies served etc)
tested, and:
- it WILL inflate the company count on the Career view (basically, branches of certain companies are counted as separate companies now, but some branches will still be merged, so the number for visited companies will be mostly meaningless)
- it WILL slightly mess up the Company Browser (basically, some branches of certain companies will appear as a separate company now)
- "certain companies": only those companies that actually have two separate branches in the same city somewhere

=head1 OPTIONS

C<--thumbnail>, C<-t> = path to the mod thumbnail in JPEG format; optional

C<--dir> = path to the mod directory to be created; give empty string to use default path; optional (meant for debugging)

C<--mod-version> = set version number to be written into the manifest (meant for cases where multiple mod versions are released for the same game version; suggested numbering scheme "1.49-beta", "1.49", "1.49-2")

C<--compatible-versions> = include compatible_versions declaration in mod manifest (C<--no-compatible-versions> to skip it, which is the default)

C<--replace>, C<-r> = replace the directory contents, if any

C<--clean> = if used along with --dir --replace, deletes all directory contents

C<--game> = control data source

C<--verbose> = additional debugging output

=head1 SEE ALSO

L<https://forum.scssoft.com/viewtopic.php?t=326360>

=cut

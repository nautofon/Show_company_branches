#! /usr/bin/env perl

use v5.36;

use ATS_DB;
use Getopt::Long 2.33 qw( :config posix_default gnu_getopt auto_version auto_help );
use IO::Compress::Zip qw( :constants $ZipError );
use List::Util 1.45 qw( any none min uniqstr );
use Pod::Usage qw( pod2usage );
use Path::Tiny 0.125;

my $MODS_DIR = '~/Library/Application Support/American Truck Simulator/mod';
my $MOD_SLUG = 'Show_company_branches';

# The branch ID tokens are sometimes not very human-readable.
my %ID_PARTS_READABLE = (
  bn_live_auc  => [qw( auc )],
  cm_min_qryp  => [qw( qry )],
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
  asu_car_pln  => 'dlc_tx',
  cal_car_exp  => 'dlc_ks',
  cal_car_pln  => 'dlc_ks',
  ch_wd_hrv    => 'dlc_tx',  # 1.50
  ch_wd_saw    => 'dlc_tx',  # 1.50
  cm_min_qryp  => 'dlc_ut',
#  flv_food_pln => 'dlc_ks',  # 1.49
  kw_trk_dlr   => 'dlc_kenworth_t680',
  kw_trk_pln   => 'dlc_kenworth_t680',
  nls_rd_grg   => 'dlc_ne',
  nmq_min_pln1 => 'dlc_mt',
  nmq_min_qrya => 'dlc_wy',
  tay_con_sit1 => 'dlc_tx',  # 1.50
  vor_oil_sit  => 'dlc_tx',
  vor_oil_str  => 'dlc_ok',  # 1.50
);
# To get an updated list:
# scs_archive --list-files | grep 'def/company\.dlc_' | scs_archive --extract - --output - | grep include | sort | perl -pe "s/\@include \"company\//\t/;s/\.dlc_/ => 'dlc_/;s/\.sui\"/',/"
# But that list should be limited to those companies that actually do
# appear multiple times. To identify these, look at the --verbose output.



my %options = ( thumbnail => '' );
GetOptions(
  'dir=s' => \$options{dir},
  'man' => \$options{man},
  'replace|r' => \$options{replace},
  'clean' => \$options{clean},
  'thumbnail|t=s' => \$options{thumbnail},
  'sii' => \$options{sii},
  'version=s' => \$options{version},
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

my %ZIP_OPTS = (
  Method => ZIP_CM_STORE,
  Minimal => 1,
  TextFlag => 1,
  ZipComment => $file->basename,
);
my $zip;

sub write_file ( $name, $data, $zip_opts = {} ) {
  if ($dir) {
    my $subdir = $dir->child($name)->parent;
    $subdir->mkdir unless $subdir->exists;
  }
  $dir->child($name)->spew_raw($data) if $dir;
  my %zip_opts = ( %ZIP_OPTS, name => $name, $zip_opts->%* );
  $zip and $zip->newStream(%zip_opts);
  $zip //= IO::Compress::Zip->new($file->openw_raw, %zip_opts);
  $zip or die "IO::Compress::Zip failed: $ZipError\n";
  $zip->write($data);
}



ats_db(%options);

my $game_version = ats_db->version;
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

write_file 'manifest.sii', <<END;
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

write_file 'description.txt', <<END;
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
  write_file 'thumbnail.jpg', $thumbnail, { TextFlag => 0 };
}



my @all_locs = ats_db->all_locations;
my @companies =
  sort { $a->name cmp $b->name }
  map { ats_db->get(company => $_) }
  ats_db->all_ids('company');

COMPANY:
for my $company (@companies) {
  my @branches =
    map { ats_db->get(branch => $_) } sort
    grep { my $id = $_; any { $_->{branch}->id eq $id } @all_locs }
    ats_db->all_ids_for(branch => company => $company->id);
  next COMPANY unless @branches > 1;
  
  # Skip companies that never have two locations in the same city
  # (This could probably be further improved by also skipping *branches*
  # that only ever appear alone in a city.)
  my @company_locs = grep { $_->{company}->id eq $company->id } @all_locs;
  my @loc_cities = sort { $a->id cmp $b->id } map { $_->{city} } @company_locs;
  my @cities = uniqstr @loc_cities;
  next COMPANY if @loc_cities == @cities;
  
  # Prepare short human-readable branch ids
  my @id_parts_branches = map {[ split '_', $_->id ]} @branches;
  my $i = 0;
  ++$i while
    none { $_ ne ($id_parts_branches[0]->[$i] // '') }
    map { $_->[$i] // '' } @id_parts_branches;
  my $id_parts_common = $i;
  my %id_parts_readable;
  for my $branch (@branches) {
    my @id_parts = split '_', $branch->id;
    shift @id_parts for 1 .. min( $id_parts_common, $#id_parts );
    @id_parts = $ID_PARTS_READABLE{$branch->id}->@* if $ID_PARTS_READABLE{$branch->id};
    $id_parts_readable{$branch->id} = join ' ', @id_parts;
  }
  
  # QA: Verify that there is no city with two company locations that
  # share the same human-readable branch id
  for my $city (@cities) {
    my @ids = sort
      map { $id_parts_readable{$_->{branch}->id} }
      grep { $_->{city}->id eq $city->id } @company_locs;
    die sprintf "Duplicate human-readable branch ids for %s in %s",
      $company->name, $city->name if @ids != uniqstr @ids;
  }
  
  # Write new def files for all branches of affected companies
  for my $branch (@branches) {
    my $name = $company->name;
    $name .= " /" . $id_parts_readable{$branch->id} . "";
    
    if ($options{verbose}) {
      my $dlc = ($DLC{$branch->id} // '') =~ s/.*(?:^|_)[^_]*?(...?)$/$1/r;
      say sprintf '%-12s %3s  %-28s "%s"',
        $branch->id, $dlc, $name, lc $branch->long_desc;
    }
    
    my %sui = (
      branch_id    => $branch->id,
      name         => $name,
      sort_name    => lc $name,
      trailer_look => $branch->{trailer_look},
    );
    my @filenames = $branch->id . '.sui';
    push @filenames, $branch->id . '.' . $DLC{$branch->id} . '.sui' if $DLC{$branch->id};
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

$zip->close;



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

C<--sii>, C<--version> = control data source

C<--verbose> = additional debugging output

=head1 SEE ALSO

L<https://forum.scssoft.com/viewtopic.php?t=326360>

=cut

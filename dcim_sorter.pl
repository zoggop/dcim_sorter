#!/usr/bin/perl

# use strict; 
# use warnings;
use File::Find;
use File::stat;
use File::Path qw(make_path);
use File::Copy;
use Image::ExifTool qw(:Public);
use DateTime;
use Win32::DriveInfo;
use Term::ReadKey;

# moves images from media into EXIF and date-sorted directories

my $oldEnough = 30; # beyond this many days old, files can be deleted from source if they're present in destination
my $minSpace = 1000; # MB less than this much space (in megabytes) on the source drive, you'll be asked if you want to delete some of the oldest images
my @exts = ('dng', 'cr2', 'cr3', 'nef', '3fr', 'arq', 'crw', 'cs1', 'czi', 'dcr', 'erf', 'gpr', 'iiq', 'k25', 'kdc', 'mef', 'mrw', 'nrw', 'orf', 'pef', 'r3d', 'raw', 'rw2', 'rwl', 'rwz', 'sr2', 'srf', 'srw', 'x3f'); # files with these exntensions will be copied to raw destination
my @nonRawExts = ('jpg', 'jpeg', 'png', 'webp', 'heif', 'heic', 'avci', 'avif');
my @sidecarExts = ('pp3', 'pp2', 'arp', 'xmp');
my $destDir = 'C:\Users\zoggop\Raw'; # where to copy raw files into directory structure
my $nonRawDestDir = 'C:\Users\zoggop\Pictures'; # where to copy non-raw images into directory structure
my $pathForm = '#Model#\%Y\%Y-%m'; # surround EXIF tags with #, and can use POSIX datetime place-holder
my @otherDirs = ('C:\Users\zoggop\Raw\dark-frames', 'C:\Users\zoggop\Raw\flat-fields'); # directories to look for copies other than the destination directories

my $srcDir = $ARGV[0];

my ($wchar, undef, undef, undef) = GetTerminalSize();

my @destPath = split(/\\/, $destDir);
my @nonRawDestPath = split(/\\/, $nonRawDestDir);
my @srcPath = split(/\\/, $srcDir);

my $srcContainsDest = 1;
for ($i = 0; $i <= $#srcPath; $i++) {
	my $ddir = $destPath[$i];
	my $nrddir = $nonRawDestPath[$i];
	my $sdir = $srcPath[$i];
	unless ($ddir eq $sdir || $nrddir eq $sdir) {
		$srcContainsDest = 0;
		last;
	}
}
my $destContainsSrc = 1;
for ($i = 0; $i <= $#destPath; $i++) {
	my $ddir = $destPath[$i];
	my $nrddir = $nonRawDestPath[$i];
	my $sdir = $srcPath[$i];
	unless ($ddir eq $sdir || $nrddir eq $sdir) {
		$destContainsSrc = 0;
		last;
	}
}


if ($destContainsSrc == 1 || $srcContainsDest == 1) {
	if ($srcContainsDest == 1) {
		print("source directory contains or is the same as destination directory\n");
	} elsif ($destContainsSrc == 1) {
		print("destination directory contains or is the same as source directory\n");
	}
	print("source: \t$srcDir\ndestination: \t$destDir\nnon-raw destination: \t$nonRawDestDir\n");
	print("press ENTER to exit");
	<STDIN>;
	exit;
}

# create extension hashes
my %validExts;
foreach my $ext (@exts) {
	$validExts{uc("\.$ext")} = 1;
}
my %nonRawValidExts;
foreach my $ext (@nonRawExts) {
	$nonRawValidExts{uc("\.$ext")} = 1;
}

my $fileCount = 0;
my $dupeCount = 0;
my $copyCount = 0;

my @safeOldImageCount = 0;
my %safeOldImagesExist;
my %datesBySafeImageFilepaths;
my %datesByCopiedFiles;
my %sourcesByCopiedFiles;
my %potentiallyEmptyPathYes;

my $nowDT = DateTime->now();
my $oldestDT;
my $newestDT;

my $exifTool = new Image::ExifTool;

my $dotStr = "";

sub image_datetime {
	my $filepath = $_[0];
	unless (-e $filepath) {
		return;
	}
	my $dt;
	$exifTool->ExtractInfo($filepath);
	my $dt_string = $exifTool->GetValue('DateTimeOriginal');
	if (length($dt_string) > 1) {
		# use exif datetime
		# print("$dt_string\n");
		my @spaced = split(/ /, $dt_string);
		my ($year, $mon, $mday) = split(/\:/, $spaced[0]);
		my ($hour, $min, $sec) = split(/\:/, $spaced[1]);
		$dt = DateTime->new(
		    year       => $year,
		    month      => $mon,
		    day        => $mday,
		    hour       => $hour,
		    minute     => $min,
		    second     => $sec);
	} else {
		# use modification datetime
		my $file_epoch = stat($filepath)->mtime;
		$dt = DateTime->from_epoch( epoch => $file_epoch );
	}
	return $dt;
}

sub prep_path {
	my $path = $_[0];
	my @pathList = split(/\\/, $path);
	my $curPath = "$pathList[0]";
	for ($i = 1; $i <= $#pathList; $i++) {
		my $dir = $pathList[$i];
		$curPath = "$curPath\\$dir";
		unless (-e $curPath) {
			make_path($curPath);
		}
	}
}

sub parse_format_string {
	my $format = $_[0];
	my $dt = $_[1];
	my $file = $_[2];
	my $formatted = $dt->strftime($format);
	my @tags = $formatted =~ /\#(.*?)\#/g;
	$exifTool->ExtractInfo($file);
	foreach my $tag (@tags) {
		my $value = $exifTool->GetValue($tag);
		$formatted =~ s/\#$tag\#/$value/g;
	}
	return $formatted;
}

sub unlink_sidecars {
	my $file = $_[0];
	my ($pathAndName) = $file =~ /.*(?=\.)/g;
	# print("$pathAndName\n");
	foreach my $scExt (@sidecarExts) {
		my @sidecarFiles = ("$file.$scExt", "$pathAndName.$scExt");
		for ($i = 0; $i <= $#sidecarFiles; $i++) {
			my $scf = $sidecarFiles[$i];
			if (-e $scf) {
				print("X $scf\n");
				unlink($scf) or warn "Could not unlink $scf: $!";
			}
		}
	}
}

sub unlink_image {
	my $file = $_[0];
	print("X $file\n");
	unlink $file or warn "Could not unlink $file: $!";
	unlink_sidecars($file);
	my ($path) = $file =~ /.*(?=\\)/g;
	# print("$path\n");
	$potentiallyEmptyPathYes{$path} = 1;
}

sub process_file {
	my $file = $_;
	my $srcFile = $File::Find::name;
	$srcFile =~ s/\//\\/g;
	my ($ext) = $file =~ /(\.[^.]+)$/;
	my ($pathAndName) = $srcFile =~ /.*(?=\.)/g;
	if ($validExts{uc($ext)} == 1 || $nonRawValidExts{uc($ext)} == 1) {
		$fileCount++;
		my $srcDT = image_datetime($srcFile);
		if ($fileCount == 1) { $oldestDT = $srcDT; }
		if ($fileCount == 1) { $newestDT = $srcDT; }
		if (DateTime->compare($srcDT, $oldestDT) == -1) {
			$oldestDT = $srcDT;
		}
		if (DateTime->compare($srcDT, $newestDT) == 1) {
			$newestDT = $srcDT;
		}
		my $destSubPath = parse_format_string($pathForm, $srcDT, $srcFile);
		my $destPath;
		if ($nonRawValidExts{uc($ext)} == 1) {
			$destPath = "$nonRawDestDir\\$destSubPath";
		} else {
			$destPath = "$destDir\\$destSubPath";
		}
		my $destFile = "$destPath\\$file";
		my $found = 0;
		my @dirs = ($destPath, @otherDirs);
		foreach my $dir (@dirs) {
			my $lookFile = "$dir\\$file";
			if (-e $lookFile && -s $lookFile == -s $srcFile && DateTime->compare($srcDT, image_datetime($lookFile)) == 0) {
				$found = 1;
				# print("found in $lookFile\n");
				last;
			}
		}
		if ($found == 1) {
			my $days = $nowDT->delta_days($srcDT)->delta_days;
			# print(" $days days old ");
			if ($days > $oldEnough) {
				$safeOldCount++;
				$safeOldImagesExist{$srcFile} = 1;
			}
			$datesBySafeImageFilepaths{$srcFile} = $srcDT;
			$dupeCount++;
			if ($dotStr ne "") {
				if (length($dotStr) == $wchar) {
					$dotStr = "";
				}
				print("\033[F");
			}
			$dotStr = "$dotStr.";
			print("$dotStr\n");
		} else {
			# if file isn't found, make necessary directories and copy it
			$copyCount++;
			print("$srcFile\n\-\> $destFile\n");
			$dotStr = "";
			prep_path($destPath);
			copy($srcFile, $destFile) or die "Copy failed: $!";
			$datesByCopiedFiles[$destFile] = $srcDT;
			$sourcesByCopiedFiles[$destFile] = $srcFile;
		}
		# copy sidecar files if present
		foreach my $scExt (@sidecarExts) {
			my @sidecarFiles = ("$srcFile.$scExt", "$pathAndName.$scExt");
			my @destSidecarFiles = ("$destFile.$scExt", "$destPathAndName.$scExt");
			for ($i = 0; $i <= $#sidecarFiles; $i++) {
				my $scf = $sidecarFiles[$i];
				my $dscf = $destSidecarFiles[$i];
				if (-e $scf) {
					unless (-e $dscf) {
						print("$scf\n\-\> $dscf\n");
						$dotStr = "";
						copy($scf, $dscf) or warn "Copy failed: $!";
					}
				}
			}
		}
	}
}

print("$srcDir\n");

find(\&process_file, ($srcDir));

print("$fileCount images found in source, $dupeCount copies found in destination, $copyCount copied\n");
if ($fileCount > 0) {
	my $oldestStrf = $oldestDT->strftime('%F %H:%M');
	my $newestStrf = $newestDT->strftime('%F %H:%M');
	print("images found span from $oldestStrf to $newestStrf\n");
}

# check copied files and add to safe to delete list if okay
foreach my $destFile (keys %sourcesByCopiedFiles) {
	my $srcFile = $sourcesByCopiedFiles[$destFile];
	my $srcDT = $datesByCopiedFiles[$destFile];
	if (-e $destFile && -s $srcFile == -s $destFile && DateTime->compare($srcDT, image_datetime($destFile)) == 0) {
		my $days = $nowDT->delta_days($srcDT)->delta_days;
		# print(" $days days old ");
		if ($days > $oldEnough) {
			$safeOldCount++;
			$safeOldImagesExist{$srcFile} = 1;
		}
		$datesBySafeImageFilepaths[$srcFile] = $srcDT;
	}
}

if ($srcPath[0] ne $destPath[0] && $fileCount > 0) {
	# source is a different drive than destination
	my (undef, undef, undef, undef, undef, $total, $free) = Win32::DriveInfo::DriveSpace($srcPath[0]);
	my $totalMB = int($total / 1000000);
	my $freeMB = int($free / 1000000);
	if ($freeMB < $minSpace) {
		print("$totalMB MB total\n$freeMB MB free on source drive $srcPath[0]\n");
		my $wantedMB = $minSpace - $freeMB;
		print ("less than $minSpace MB free on source drive $srcPath[0]. would you like to delete the oldest safely copied images to free up $wantedMB MB? (y/N)\n");
		my $yesDelete = <STDIN>;
		chomp($yesDelete);
		if (uc($yesDelete) eq 'Y') {
			@safeFilepaths = sort { DateTime->compare_ignore_floating($datesBySafeImageFilepaths{$a}, $datesBySafeImageFilepaths{$b}) } keys(%datesBySafeImageFilepaths);
			my $deletedMB = 0;
			foreach my $fp (@safeFilepaths) {
				if (%safeOldImagesExist{$fp} == 1) {
					$safeOldCount = $safeOldCount - 1;
					$safeOldImagesExist{$fp} = 0;
				}
				my $fpMB = -s $fp;
				$fpMB = $fpMB / 1000000;
				unlink_image($fp);
				$deletedMB = $deletedMB + $fpMB;
				$freeMB = $freeMB + $fpMB;
				if ($freeMB > $minSpace) {
					last;
				}
			}
			print("deleted $deletedMB MB of the oldest safely copied images. $freeMB MB now available on source drive $srcPath[0]\n");
		}
	}
}

if ($safeOldCount > 0) {
	print("\ndelete $safeOldCount safely copied images older than $oldEnough days from source? (y/N) ");
	my $yesDelete = <STDIN>;
	chomp($yesDelete);
	if (uc($yesDelete) eq 'Y') {
		foreach my $file (keys %safeOldImagesExist) {
			if ($safeOldImagesExist{$file} == 1) {
				unlink_image($file);
			}
		}
		print("$safeOldCount images deleted from source\n");
	}
}

foreach my $path (keys %potentiallyEmptyPathYes) {
	# print("$path\n");
	if (rmdir($path)) {
		print("X $path\n");
	}
}

print("press ENTER to exit");
<STDIN>;
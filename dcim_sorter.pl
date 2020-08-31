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

# moves images from media into date-sorted directories

my $oldEnough = 365; # beyond this many days old, files can be deleted from source if they're present in destination
my $minSpace = 1000; # MB less than this much space (in megabytes) on the source drive, you'll be asked if you want to delete some of the oldest images
my $dated_filenames = 0; # put date and time in destination filenames?
my @exts = ('jpg', 'jpeg', 'dng', 'cr2', 'cr3', 'png', 'nef'); # files with these exntensions will be copied
my $destDir = 'C:\Users\zoggop\Pictures\eos350d'; # where to copy files into by-date directory structure

my $srcDir = $ARGV[0];

my @destPath = split(/\\/, $destDir);
my @srcPath = split(/\\/, $srcDir);

my $srcContainsDest = 1;
for ($i = 0; $i <= $#srcPath; $i++) {
	my $ddir = $destPath[$i];
	my $sdir = $srcPath[$i];
	unless ($ddir eq $sdir) {
		$srcContainsDest = 0;
		last;
	}
}
my $destContainsSrc = 1;
for ($i = 0; $i <= $#destPath; $i++) {
	my $ddir = $destPath[$i];
	my $sdir = $srcPath[$i];
	unless ($ddir eq $sdir) {
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
	print("source: \t$srcDir\ndestination: \t$destDir\n");
	print("press ENTER to exit");
	<STDIN>;
	exit;
}

# create extension hash
my %validExts;
foreach my $ext (@exts) {
	$validExts{uc("\.$ext")} = 1;
}

my $fileCount = 0;
my $dupeCount = 0;
my $copyCount = 0;

my @safeOldImageCount = 0;
my %safeOldImagesExist;
my %datesBySafeImageFilepaths;

sub image_datetime {
	my $filepath = $_[0];
	my $only_datetime = $_[1];
	unless (-e $filepath) {
		return;
	}
	# print("$filepath, $only_datetime\n");
	my $year, $mon, $mday, $hour, $min, $sec;
	my $exifTool = new Image::ExifTool;
	$exifTool->ExtractInfo($filepath);
	my $dt_string = $exifTool->GetValue('DateTimeOriginal');
	if (length($dt_string) > 1) {
		# use exif datetime
		# print("$dt_string\n");
		@spaced = split(/ /, $dt_string);
		($year, $mon, $mday) = split(/\:/, $spaced[0]);
		($hour, $min, $sec) = split(/\:/, $spaced[1]);
	}
	else {
		# use modification datetime
		my $datetime = stat($filepath)->mtime;
		my $wday, $yday, $isdst;
		($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($datetime);
		$year = $year + 1900;
		$mon = sprintf "%02d", $mon;
		$mday = sprintf "%02d", $mday;
	}
	# print("$file $year\/$mon\/$mday $hour\:$min\:$sec\n");
	my $dt = DateTime->new(
	    year       => $year,
	    month      => $mon,
	    day        => $mday,
	    hour       => $hour,
	    minute     => $min,
	    second     => $sec);
	if ($only_datetime == 1) {
		return $dt;
	} else {
		return $year, $mon, $mday, $hour, $min, $sec, $dt;
	}
}

sub process_file {
	my $file = $_;
	$srcFile = $File::Find::name;
	$srcFile =~ s/\//\\/g;
	my ($ext) = $file =~ /(\.[^.]+)$/;
	if ($validExts{uc($ext)} == 1) {
		$fileCount++;
		my ($year, $mon, $mday, $hour, $min, $sec, $srcDT) = image_datetime($srcFile, 0);
		my $destFile = "$destDir\\$year\\$year\-$mon\\$year-$mon-$mday\\";
		if ($dated_filenames) {
			$destFile = $destFile . "$year-$mon-$mday-$hour\_$min\_$sec-";
		}
		$destFile = $destFile . "$file";
		my $destDT = image_datetime($destFile, 1);
		if (-e $destFile && -s $destFile == -s $srcFile && DateTime->compare($srcDT, $destDT) == 0) {
			my $nowDT = DateTime->now();
			my $days = $nowDT->delta_days($srcDT)->delta_days;
			# print(" $days days old ");
			if ($days > $oldEnough) {
				$safeOldCount++;
				$safeOldImagesExist{$srcFile} = 1;
			}
			$datesBySafeImageFilepaths{$srcFile} = $srcDT;
			$dupeCount++;
		} else {
			# if file isn't already in destination, create necessary directories and copy it there
			$copyCount++;
			print("$file $year\/$mon\/$mday $hour\:$min\:$sec\n");
			print("$srcFile\n\-\> $destFile\n");
			unless (-e "$destDir\\$year") {
				make_path("$destDir\\$year")
			}
			unless (-e "$destDir\\$year\\$year\-$mon") {
				make_path("$destDir\\$year\\$year\-$mon")
			}
			unless (-e "$destDir\\$year\\$year\-$mon\\$year-$mon-$mday") {
				make_path("$destDir\\$year\\$year\-$mon\\$year-$mon-$mday")
			}
			copy($srcFile, $destFile) or die "Copy failed: $!";
		}
		# copy the processing profile if present
		$pp3File = "$srcFile.pp3";
		if (-e $pp3File) {
			$destPp3File = "$destFile.pp3";
			unless (-e $destPp3File) {
				print("$pp3File\n\-\> $destPp3File\n");
				copy($pp3File, $destPp3File) or die "Copy failed: $!";
			}
		}
	}
}

find(\&process_file, ($srcDir));
print("$fileCount images found in source, $dupeCount copies found in destination, $copyCount copied\n");

if ($srcPath[0] ne $destPath[0]) {
	# source is a different drive than destination
	# my ($fs_type, $fs_desc, $used, $avail, $fused, $favail) = df $srcDir;
	my (undef, undef, undef, undef, undef, $total, $free) = Win32::DriveInfo::DriveSpace($srcPath[0]);
	my $totalMB = int($total / 1000000);
	my $freeMB = int($free / 1000000);
	if ($freeMB < $minSpace) {
		print("$totalMB MB total\n$freeMB MB free\n");
		my $wantedMB = $minSpace - $freeMB;
		print ("less than $minSpace MB free on source drive. would you like to delete the oldest safely copied images to free up $wantedMB MB? (y/N)\n");
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
				print("X $fp\n");
				unlink $fp or warn "Could not unlink $fp: $!";	
				$deletedMB = $deletedMB + $fpMB;
				$freeMB = $freeMB + $fpMB;
				if ($freeMB > $minSpace) {
					last;
				}
			}
			print("deleted $deletedMB MB of the oldest safely copied images. $freeMB MB now available on source drive.\n");
		}
	}
}

# my @allPosts = sort { $datenumbers{$b} <=> $datenumbers{$a} } keys(%datenumbers

if ($safeOldCount > 0) {
	print("\ndelete $safeOldCount safely copied images older than $oldEnough days from source? (y/N) ");
	my $yesDelete = <STDIN>;
	chomp($yesDelete);
	if (uc($yesDelete) eq 'Y') {
		foreach my $file (keys %safeOldImagesExist) {
			if ($safeOldImagesExist{$file} == 1) {
				print("X $file\n");
				unlink $file or warn "Could not unlink $file: $!";
			}
		}
		print("$safeOldCount images deleted from source\n");
	}
}
print("press ENTER to exit");
<STDIN>;
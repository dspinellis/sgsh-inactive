#!/usr/bin/perl
#
# Read as input a shell script extended with scatter-gather operation syntax
# Produce as output and execute a plain shell script implementing the
# specified operations through named pipes
#
#  Copyright 2012-2013 Diomidis Spinellis
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

use strict;
use warnings;
use File::Temp qw/ tempfile /;
use Getopt::Std;

# Command-line options
# -k		Keep temporary file
# -n		Do not run the generated script
# -s shell	Specify shell to use
# -t tee	Path to teebuff

our($opt_s, $opt_t, $opt_k, $opt_n);
$opt_s = '/bin/sh';
$opt_t = 'teebuff';
getopts('kns:t:');

$File::Temp::KEEP_ALL = 1 if ($opt_k);

# Output file
my ($output_fh, $output_filename) = tempfile(UNLINK => 1);

# The scatter point currently in effect
my $current_point;

# For assigning unique scatter point ids
my $point_counter;

# Used for saving/restoring current_point
my @current_point_stack;

# Number of endpoints for each scatter point
my @endpoint_number;

# True when processing a scatter gather block
my $in_scatter_gather_block = 0;

# Number of gather variable input points
my $gather_variable_points;

# Number of gather file input points
my $gather_file_points;

# Line where S/G block starts
my $scatter_gather_start;

# Variable name for each variable (|=) gather endpoint
my @gather_variable_name;

# File name for each file (|>) gather endpoint
my @gather_file_name;

# Map containing all defined gather file names
my %gather_file_defined;

# Lines of the input file
# Required, because we implement a double-pass algorithm
my @lines;

# User-specified input file name (or STDIN)
my $input_filename;

# Regular expressions for the input files scatter-gather operators
# scatter |{
my $SCATTER_BLOCK_BEGIN = q!^[^'#"]*scatter\s*\|\{\s*(\#.*)?$!;
# |{
my $SCATTER_BEGIN = q!\|\{\s*(\#.*)?$!;
# |} gather |{
my $GATHER_BLOCK_BEGIN = q!^[^'#"]*\|\}\s*gather\s*\|\{\s*(\#.*)?$!;
# |}
my $BLOCK_END = q!^[^'#"]*\|\}\s*(\#.*)?$!;
# -|
my $SCATTER_INPUT = q!^[^'#"]*-\|!;
# |= name
my $GATHER_VARIABLE_OUTPUT = q!\|\=\s*(\w+)\s*(\#.*)?$!;
# |>/sgsh/name
my $GATHER_FILE_OUTPUT = q!\|\>\s*\/sgsh\/(\w+)\s*(\#.*)?$!;
# -||>/sgsh/name
my $SCATTER_GATHER_PASS_THROUGH = q!^[^'#"]*-\|\|\>\s*\/sgsh\/(\w+)\s*(\#.*)?$!;

# Read input file
if ($#ARGV >= 0) {
	$input_filename = shift;
	open(my $in, '<', $input_filename) || die "Unable to open $input_filename: $!\n";
	@lines = <$in>;
} else {
	$input_filename = 'STDIN';
	@lines = <STDIN>;
}

print $output_fh "#!$opt_s
# Automatically generated file
# Source file $input_filename
";


# Adjust command interpreter line
$lines[0] =~ s/^\#\!/#/;

# Process file's lines
for (my $i = 0; $i <= $#lines; $i++) {
	$_ = $lines[$i];
	# Scatter block begin
	if (/$SCATTER_BLOCK_BEGIN/o) {
		if ($in_scatter_gather_block) {
			print STDERR "$input_filename(", $i + 1, "): Scatter-gather blocks can't be nested\n";
			exit 1;
		}
		$point_counter = -1;
		$gather_variable_points = 0;
		$gather_file_points = 0;
		$scatter_gather_start = $i;
		$in_scatter_gather_block = 1;
		undef @endpoint_number;
		undef @current_point_stack;
		undef @gather_variable_name;
		next;

	# Gather block begin
	} elsif (/$GATHER_BLOCK_BEGIN/o) {
		if ($#current_point_stack != -1) {
			print STDERR "$input_filename(", $i + 1, "): Missing |}\n";
			exit 1;
		}
		generate_scatter_code($scatter_gather_start, $i - 1);
		$i += generate_gather_code($i);
		$in_scatter_gather_block = 0;
		next;

	# Scatter group end
	} elsif (/$BLOCK_END/o) {
		if ($#current_point_stack == -1) {
			print STDERR "$input_filename(", $i + 1, "): Extra |}\n";
			exit 1;
		}
		$current_point = pop(@current_point_stack);
		next;
	}

	# Scatter input endpoint
	if (/$SCATTER_INPUT/o) {
		$endpoint_number[$current_point]++;
	}

	# Scatter group begin
	if (/$SCATTER_BEGIN/o) {
		push(@current_point_stack, $current_point);
		$current_point = ++$point_counter;
	}

	# Gather variable output endpoint
	if (/$GATHER_VARIABLE_OUTPUT/o) {
		$gather_variable_name[$gather_variable_points++] = $1;
	}

	# Gather file output endpoint
	if (/$GATHER_FILE_OUTPUT/o) {
		$gather_file_name[$gather_file_points++] = $1;
		$gather_file_defined{$1} = 1;
	}


	# Print the line, unless we're in a scatter-gather block
	print $output_fh $_ unless ($in_scatter_gather_block);
}

# Execute the shell on the generated file
# -a inherits the shell's variables to subshell
my @args = ($opt_s, '-a', $output_filename, @ARGV);

if ($opt_n) {
	print join(' ', @args), "\n";
	exit 0;
}

system(@args);
if ($? == -1) {
	print STDERR "Unable to execute $opt_s: $!\n";
	exit 1;
} else {
	# Convert Perl's system exit code into one compatible with sh(1)
	exit (($? >> 8) | (($? & 127) << 8));
}

#
# Generate the code to scatter data
# Arguments are the beginning and end lines of the corresponding scatter block
# Uses the global variables: @lines, $point_counts, @endpoint_number, $gather_variable_points
#
sub
generate_scatter_code
{
	my($start, $end) = @_;
	# The scatter point currently in effect
	my $current_point;

	# For assigning unique scatter point ids
	my $point_counter = -1;

	# Used for saving/restoring current_point
	my @current_point_stack;

	# Count endpoints for each scatter point
	my @endpoint_counter;

	for (my $i = $start; $i <= $end; $i++) {
		$_ = $lines[$i];
		# Scatter block begin: initialize named pipes
		if (/$SCATTER_BLOCK_BEGIN/o) {
			# Generate initialization code
			# The traps ensure that the named pipe directory
			# is removed on termination and that the exit code
			# after a signal is that of the shell: 128 + signal number
			my $code = q{export SGDIR=/tmp/sg-$$; rm -rf $SGDIR; trap 'rm -rf "$SGDIR"' 0; trap 'exit $?' 1 2 3 15; mkdir $SGDIR; mkfifo};
			# Scatter named pipes
			for (my $j = 0; $j <= $#endpoint_number; $j++) {
				for (my $k = 0; $k < $endpoint_number[$j]; $k++) {
					$code .= " \$SGDIR/npi-$j.$k";
				}
			}
			# Gather variable named pipes
			for (my $j = 0; $j < $gather_variable_points; $j++) {
				$code .= " \$SGDIR/npvo-$gather_variable_name[$j]";
			}

			# Gather file named pipes
			for (my $j = 0; $j < $gather_file_points; $j++) {
				$code .= " \$SGDIR/npfo-$gather_file_name[$j]";
			}
			s/scatter\s*\|\{/$code/;

		# Gather group begin
		} elsif (/$GATHER_BLOCK_BEGIN/o) {
			generate_scatter_code($scatter_gather_start, $i - 1);
			$i += generate_gather_code($i);

		# Scatter group end: maintain stack
		} elsif (/$BLOCK_END/o) {
			$current_point = pop(@current_point_stack);
			s/\|\}//;

		}

		# Scatter-gather pass-through to a named file
		# Pass the output through tuboflo to avoid deadlock
		if (/$SCATTER_GATHER_PASS_THROUGH/o) {
			s/-\|/<\$SGDIR\/npi-$current_point.$endpoint_counter[$current_point]/;
			s/\|\>\s*\/sgsh\/(\w+)/ tuboflo >\$SGDIR\/npfo-$1 &/;
		}

		# Scatter input head endpoint: get input from named pipe
		if (/$SCATTER_INPUT/o) {
			s/-\|/<\$SGDIR\/npi-$current_point.$endpoint_counter[$current_point]/;
			$endpoint_counter[$current_point]++;
		}

		# Scatter group begin: tee output to named pipes
		if (/$SCATTER_BEGIN/o) {
			push(@current_point_stack, $current_point) if (defined($current_point));
			$current_point = ++$point_counter;
			my $tee_args;
			my $j;
			for ($j = 0; $j  < $endpoint_number[$current_point]; $j++) {
				$tee_args .= " \$SGDIR/npi-$current_point.$j";
			}
			s/\|\{/| $opt_t $tee_args &/;
			$endpoint_counter[$current_point] = 0;
		}

		# Gather output endpoint to named variable
		if (/$GATHER_VARIABLE_OUTPUT/o) {
			s/\|\=\s*(\w+)/>\$SGDIR\/npvo-$1 &/;
		}

		# Gather output endpoint to named file
		# Pass the output through tuboflo to avoid deadlock
		if (/$GATHER_FILE_OUTPUT/) {
			s/\|\>\s*\/sgsh\/(\w+)/| tuboflo >\$SGDIR\/npfo-$1 &/;
		}

		print $output_fh $_;
	}
}

# Generate gather code for the gather block starting in the passed line
# Return the number of lines in the block
sub
generate_gather_code
{
	my($start) = @_;

	my $i;
	for ($i = $start; $i <= $#lines; $i++) {
			$_ = $lines[$i];
		if (/$GATHER_BLOCK_BEGIN/o) {
			s/\|\}\s*gather\s*\|\{//;
			print $output_fh "# Gather the results\n(\n";
			for (my $j = 0; $j <= $#gather_variable_name; $j++) {
				print $output_fh qq{\techo "$gather_variable_name[$j]='`cat \$SGDIR/npvo-$gather_variable_name[$j]`'" &\n};
			}
			print $output_fh "\twait\ncat <<\\SGEOFSG\n";
		} elsif (/$BLOCK_END/o) {
			s/\|\}//;

			# -s allows passing positional arguments to subshell
			print $output_fh qq{SGEOFSG\n) | $opt_s -s "\$@"\n};
			last;
		} else {
			# Substitute /sgsh/... gather points with corresponding named pipe
			while ($lines[$i] =~ m|/sgsh/(\w+)|) {
				my $file_name = $1;
				if (!$gather_file_defined{$file_name}) {
					print STDERR "$input_filename(", $i + 1, "): Undefined file gather name $file_name\n";
					exit 1;
				}
				$lines[$i] =~ s|/sgsh/$file_name|\$SGDIR/npfo-$file_name|g;
			}

			print $output_fh $lines[$i];
		}
	}
	return $i;
}

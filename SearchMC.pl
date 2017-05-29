#!/usr/bin/perl

use strict;
use warnings;
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);

use POSIX 'floor', 'ceil';
use IPC::Open2;
use List::Util 'shuffle';
use Time::HiRes qw(time);
use File::Basename;
use File::Copy;
use Scalar::Util qw(looks_like_number);
use Getopt::Long;

my $meanSize = 640;
my $sigmaSize = 140;
my $cryptominisat2 = "./cryptominisat";
my $cryptominisat5 = "./cryptominisat5";
my $z3 ="./z3";
my $mathsat = "./mathsat";
my $mathsat_opts =
  join(" ",
       "-preprocessor.toplevel_propagation=true",
       "-preprocessor.simplification=7", # all
       "-dpll.branching_random_frequency=0.01",
       "-dpll.branching_random_invalidate_phase_cache=true",
       "-dpll.restart_strategy=3", # dynamic like Glucose
       "-dpll.glucose_var_activity=true",
       "-dpll.glucose_learnt_minimization=true",
       "-dpll.preprocessor.mode=1", # pre-
       "-theory.bv.eager=true",
       "-theory.bv.bit_blast_mode=2", # AIG + synthesis
       "-theory.bv.delay_propagated_eqs=true",
       "-theory.arr.mode=1", # Boolector-like LoD
       "-theory.la.enabled=false",
       "-theory.eq_propagation=false",
       "-theory.fp.mode=1", # eager bit-blasting
       "-theory.fp.bit_blast_mode=2", # AIG + synthesis
       "-theory.fp.bv_combination_enabled=true",
       "-theory.euf.enabled=false",
       "-theory.arr.enabled=false");
my $temp_dir = "./temp_files";
my $sat_cnt = 0;
my $exhaust_cnt = 0;
my $solver_pid;
my @vars;

$| = 1;

## Variables
my $mu_prime;
my $sigma_prime;
my $mu;
my $sigma;
my $c;
my $k;
my $ub;
my $lb;
my $nSat;
my $true_result;

my $table_w;
my $numVariables;
my $numClauses;
my $c_max = int(2**10);

my @array_prob;
$array_prob[64][1] = undef;

## Options
my $cl;
my $thres;
my $alpha = 0;

my $mode = "batch";
my $solver = "cryptominisat2";
my $verbose = 0;
my $save_files = '';
my $xor_num_vars;
my $help = '';
my $input_type = "cnf";
my $proj_flag = '';
my $output_name;
my $random_seed = undef;

GetOptions ("thres=f" => \$thres,
"cl=f"   => \$cl,
"alpha=f"   => \$alpha,
"mode=s"   => \$mode,
"verbose=i"  => \$verbose,
"input_type=s" => \$input_type,
"save_files" => \$save_files,
"xor_num_vars=i" => \$xor_num_vars,
"output_name=s" => \$output_name,
"solver=s" => \$solver,
"random_seed=i" => \$random_seed,
"true_result=f" => \$true_result,
"help|?" => \$help)
or die("Error in command line arguments\n");

if (defined $random_seed) {
    srand($random_seed);
}
my($filename, $base_filename);

if (@ARGV == 1) {
    $filename = $ARGV[0];
    $base_filename = basename($filename);
    copy($filename,"./$base_filename"); 
    $filename = "./$base_filename";
} else {
    check_options(); # This handles -help
    die "One non-option argument required, input file name\n";
}

check_options();

mkdir ($temp_dir) unless(-d $temp_dir);

my $start = time();

## Read input file based on input type and solver
if($input_type eq "smt" && $solver eq "cryptominisat5") {
    convert_smt_to_cnf($filename);
    $filename = "./$base_filename.cnf";
    rename "./output_0.cnf", $filename
      or die "Rename of ./output_0.cnf to $filename failed: $!";
    $base_filename = basename($filename);
    read_cnf_file($filename);
} elsif ($input_type eq "smt" && ($solver eq "z3" || $solver eq "mathsat")
	 && $mode eq "batch") {
    read_smt_file($filename);
} elsif ($input_type eq "smt" && $solver eq "z3" && $mode eq "inc") {
    #read_smt_file_inc($filename);
} elsif ($input_type eq "cnf" && ($solver eq "cryptominisat2" || $solver eq "cryptominisat5")) {
    read_cnf_file($filename);
}
	 

$table_w = 64;
my $delta = $table_w;

$cl = $cl+(1-$cl) * $alpha;

init_prob_table();

## initial round
if ($numVariables > $table_w / 2) {
    $mu = $table_w / 2;
} else {
    $mu = $numVariables / 2;
}
$sigma = 1000;
$k = sprintf("%.0f", $mu);
$c = 1;

while ($delta > $thres)
{
    my $sub_start = time();
    ($c ,$k) = ComputeCandK($mu, $sigma, $c_max, $numVariables, $thres);
    if($solver eq "cryptominisat2" || $solver eq "cryptominisat5") {
        $nSat = MBoundExhaustUpToC_crypto($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt);
    } elsif ($solver eq "z3" || $solver eq "mathsat") {
        if($mode eq "inc") {
			read_smt_file_inc($filename);
            $nSat = MBoundExhaustUpToC_z3_inc($numVariables, $xor_num_vars, $k, $c, $output_name);
            end_solver();
        } elsif($mode eq "batch") {
	    if ($solver eq "z3") {
		$nSat = MBoundExhaustUpToC_z3_batch($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt, $output_name);
	    } else {
		$nSat = MBoundExhaustUpToC_smt_batch($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt, $output_name);
	    }
        }
    }
        
    $exhaust_cnt++;
    if($nSat == $c) {
        $sat_cnt=$sat_cnt+$nSat;
    } else {
        $sat_cnt=$sat_cnt+$nSat+1;
    }
    
    if ($k == 0 ) {
	if ($verbose) {
            printf "$exhaust_cnt: Old Mu = %.4f, Old Sigma = %.4f, nSat = $nSat, k = $k, c = $c\n", $mu, $sigma;
	}
        print "Result: Exact # of solutions = $nSat\n";
        last;
    } else {
        #($mu_prime, $sigma_prime) = updateDist2($mu, $sigma, $c, $k, $nSat);
        #($ub, $lb) = getBounds($mu_prime,$sigma_prime,$table_w,$cl);
        ($mu_prime, $sigma_prime, $lb, $ub) = updateDist3($mu, $sigma, $c, $k, $nSat, $cl);
        update_prob_table($c, $k, $nSat, $cl);
        if (isZero()) {
            #print "isZero = true\n";
            init_prob_table();
            update_prob_table($c, $k, $nSat, $cl);
        }
        my $sub_end = time();
        if ($verbose ) {
            printf "$exhaust_cnt: Old Mu = %.4f, Old Sigma = %.4f, nSat = $nSat, k = $k, c = $c\n", $mu, $sigma;
            printf "$exhaust_cnt: New Mu = %.4f, New Sigma = %.4f\n", $mu_prime, $sigma_prime;
            printf "$exhaust_cnt: Lower Bound = %.4f, Upper Bound = %.4f\n",$lb, $ub;
	    if (defined $true_result) {
		my $true_norm = ($true_result - $mu_prime)/$sigma_prime;
		my $cdf_true = 0.5*(1 + erf($true_norm/sqrt(2)));
		printf "$exhaust_cnt: CDF(true) = %.4f\n", $cdf_true;
		printf "$exhaust_cnt: Error = %.4f\n", abs($true_result-$mu_prime);
	    }
            printf("$exhaust_cnt: Running Time = %.4f\n", $sub_end - $sub_start);
        }
        $mu = $mu_prime;
        $sigma = $sigma_prime;
        $delta = $ub - $lb;
    }
}
if(!$save_files) {
    unlink "$temp_dir/org-$base_filename";
}

norm_prob_table();
my $sound_ub;
my $sound_lb;
($sound_lb, $sound_ub) = getSoundBounds();

my $end = time();

if ($k == 0 ) {
    print "Result: Filename = $base_filename\n";
    print "Result: #ExhaustUptoC Query = $exhaust_cnt\n";
    print "Result: #Sat Query = $sat_cnt\n";
    printf("Result: Running Time = %.4f\n", $end - $start);
} else {
    printf "$base_filename %.4f %.4f $sat_cnt %.4f", $lb, $ub, $end - $start;
    if (defined $true_result) {
	my $is_correct = ($true_result >= $lb && $true_result <= $ub);
	print " ", ($is_correct ? "correct" : "wrong");
	printf " %.4f", abs($true_result-$mu);
    }
    print "\n";
    printf "Result: Lower Bound = %.4f\n",$lb;
    printf "Result: Upper Bound = %.4f\n",$ub;
    printf "Result: Sound Lower Bound = %.4f\n",$sound_lb;
    printf "Result: Sound Upper Bound = %.4f\n",$sound_ub;
    print "Result: Filename = $base_filename\n";
    print "Result: #ExhaustUptoC Query = $exhaust_cnt\n";
    print "Result: #Sat Query = $sat_cnt\n";
    printf("Result: Running Time = %.4f\n", $end - $start);
}

sub convert_smt_to_cnf {
    my($filename) = @_;
    my $converter_pid = open2(*OUT, *IN, "./stp-2.1.2 -p --disable-simplifications --disable-cbitp --disable-equality -a -w --output-CNF --minisat $filename");
    my $num;
    while(my $line = <OUT>) {
        if ($line =~ /^VarDump: $output_name bit ([0-9]*) is SAT var ([0-9]*)$/) {
            $num = $2;
            push @vars, $num;
        }
    }
    if(not @vars) {
		die "Output $output_name not found\n"; 
	}
    close IN;
    close OUT;
    waitpid($converter_pid, 0);
}

sub check_options {
    if ($help) {
        print "Usage: SearchMC.pl -cl=<cl value> -thres=<threshold value> [options] <input CNF file>\n
        For example, ./SearchMC.pl -cl=0.9 -thres=2 -verbose=1 test.cnf\n
        \n
        Input Parameters:\n
        -cl=<cl value>: confidence level value (0 < cl < 1)\n
        -thres=<threshold value>: threshold value. The algorithm terminates when the interval is less than this value (0 < thres < output bits)\n
        \n
        Options:\n
        -input_type=<input file format>: cnf (default), smt 
        -output_name=<output name>: output variable name (eg. x, y) for projection, SMT only\n
        -xor_num_vars=<#variables for a XOR constraint> (0 < numVar < max number of variables)\n
        -verbose=<verbose level>: set verbose level; 0, 1(default)\n
        -mode=<solver mode>: solver mode; batch (default), inc (incremental mode,SMT only)\n
        -save_files : store all CNF files\n
        -true_result=<influence>: expected result for statistics";
        last;
    }
    if (defined($cl) && defined($thres)) {
		if ($cl <= 0 && $cl > 1) {
			die "Confidence level should be 0 < cl < 1";
		}
		if ($thres <= 0 && $thres > 64) {
			die "Threshold should be 0 <= thres <= 64";
		}
    
    } else {
        die "cl and thres values needed\n"
    }
    
    if($mode eq "batch") {
        
    } elsif ($mode eq "inc") {
		
	} else {
        die "Invalid mode: $mode\n";
    }
    
    if($solver eq "cryptominisat5") {
        
    } elsif ($solver eq "cryptominisat2") {
		if ($input_type ne "cnf") {
			die "$solver only works with CNF formula\n";
		}
    } elsif ($solver eq "z3" || $solver eq "mathsat") {
		if ($input_type eq "cnf") {
			die "$solver only supported with SMT-LIB2 formula\n";
		}
	} else {
        die "Invalid solver: $solver\n";
    }
    if($verbose < 0 && $verbose > 1) {
		die "Wrong verbose mode\n";
	}
	if ($input_type eq "smt") {
		if (!$output_name) {
			die "Output variable should be specified\n";
		}
	}
}

sub read_cnf_file {
    my($filename) = @_;
    ## read input file
    open(my $fh1, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename' $!";
    
    open(my $fh2, '>', "$temp_dir/org-$base_filename")
      or die "Failed to open temporary $temp_dir/org-$base_filename: $!";
    my @temp;
    while(my $line = <$fh1>) {
        if ($line =~ /^\s*p\s+cnf\s+([0-9]*)\s*([0-9]*)\s*$/) {
            print $fh2 "$line";
            $numVariables = $1;
            $numClauses = $2;
            if(@vars) {
                my $proj = join(" ", @vars);
                print $fh2 "cr $proj\n";
            } else {
                @vars = (1 .. $numVariables);
            }
        } elsif ($line =~ /^\s*$/) {
			
		} elsif ($line =~ /^cr/) {
			@vars = split ' ', $line;
			splice @vars, 0, 1;
		} else {
            print $fh2 "$line";
        }
    }
    if($xor_num_vars) {
    } else {
        $xor_num_vars = floor(scalar(@vars)/2);
    }
    close $fh1;
    close $fh2;
}

sub read_smt_file {
    my($filename) = @_;
    ## read input file
    open(my $fh1, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename' $!";
    my $file_name = basename($filename);
    
    open(my $fh2, '>', "$temp_dir/org-$file_name");

	while(my $line = <$fh1>) {
		if ($line =~ /\s*\(declare-fun\s+$output_name\s*\(\s*\)\s*\(_\s+BitVec\s+([0-9]+)\s*\)\s*\)\s*/) {
			$numVariables = $1;
		}
		if ($line =~ /\s*\(\s*check-sat\s*\)\s*\n/ || $line =~ /\s*\(\s*exit\s*\)\s*\n/ || $line =~ /\s*\(\s*get-model\s*\)\s*\n/ ) {
			
		} else {
			print $fh2 "$line";
		}
	}
	
	if(!$numVariables) {
		die "Output $output_name not found\n"; 
	}
	if($xor_num_vars) {
    } else {
        $xor_num_vars = floor($numVariables/2);
    }
	close $fh1;
	close $fh2;
}

sub read_smt_file_inc {
    my($filename) = @_;
    open_solver_inc($solver);
    ## read input file
    open(my $fh1, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename'!";

	while(my $line = <$fh1>) {
		if ($line =~ /\s*\(declare-fun\s+$output_name\s*\(\s*\)\s*\(_\s+BitVec\s+([0-9]+)\s*\)\s*\)\s*/) {
			$numVariables = $1;
		}
		if ($line =~ /\s*\(\s*check-sat\s*\)\s*\n/ || $line =~ /\s*\(\s*exit\s*\)\s*\n/ || $line =~ /\s*\(\s*get-model\s*\)\s*\n/ ) {
			
		} else {
			print IN $line;
		}
	}
	
	if(!$numVariables) {
		die "Output $output_name not found\n"; 
	}
	if($xor_num_vars) {
    } else {
        $xor_num_vars = floor($numVariables/2);
    }
	close $fh1;
}

sub run_solver {
    my($filename, $c, $solver) = @_;
    if ($solver eq "cryptominisat5") {
		my $max_sol_limited = $c;
	    # In the version I looked at, the arg to --maxsol is parsed
	    # into a uint32_t, and CMS will croak if it's out of range.
    	$max_sol_limited = 2**32-1 if $max_sol_limited > 2**32-1;
		$solver_pid = open2(*OUT, *IN, "$cryptominisat5 --autodisablegauss=0 --printsol=0 --maxsol=$max_sol_limited --verb=0 $filename");
	} elsif ($solver eq "cryptominisat2") {
		$solver_pid = open2(*OUT, *IN, "$cryptominisat2 --nosolprint --gaussuntil=400 --maxsolutions=$c --verbosity=0 $filename");
	} elsif ($solver eq "z3") {
		$solver_pid = open2(*OUT, *IN, "$z3 $filename");
	} elsif ($solver eq "mathsat") {
		$solver_pid = open2(*OUT, *IN,
				    "$mathsat -model $mathsat_opts $filename");
	}
}

sub open_solver_inc {
	my($solver) = @_;
	if ($solver eq "z3") {
		$solver_pid = open2(*OUT, *IN, "$z3 --in");
		print IN "(set-option :produce-models true)";
	} elsif ($solver eq "mathsat") {
		die "MathSAT in incremental mode is not supported\n";
	}
}

sub end_solver {
    close IN;
    close OUT;
    waitpid($solver_pid, 0);
}

sub updateDist3 {
    my($mu, $sigma, $c, $xor, $nSat, $cl) = @_;
    my $center;
    my $new_sigma;
    my $new_lb;
    my $new_ub;
    my $prior;
    my $option;
    
    #Uniform -> Truncated Normal
    if ($sigma > 100) {
        if ($nSat == $c) {
            $prior = "uniform";
            $option = "-nSatGE";
        } else {
            $prior = "uniform";
            $option = "-nSat";
        }
    #Truncated Normal -> Truncated Normal
    } else {
        if ($nSat == $c) {
            $prior = "particle";
            $option = "-nSatGE";           
        } else {
            $prior = "particle";
            $option = "-nSat";           
        }
    }
    my $cmd_pid;
    if ($prior eq "particle") {
        #$cmd_pid = open2(*OUT2, *IN2, "./one-step -prior $prior -priorparticle particle-filter.dat -filter particle -k $xor $option $nSat -cl $cl -verb 0");
        $cmd_pid = open2(*OUT2, *IN2, "./particle-filter -prior $prior -priorparticle posterior.dat -k $xor $option $nSat -cl $cl -verb 0");
        #print "./particle-filter -prior $prior -priorparticle posterior.dat -k $xor $option $nSat -cl $cl -verb 0\n";
        #print "./one-step -prior $prior -priorparticle particle-filter.dat -filter particle -k $xor $option $nSat -cl $cl -verb 0\n";
    } else {
        #$cmd_pid = open2(*OUT2, *IN2, "./one-step -prior $prior -filter particle -k $xor $option $nSat -cl $cl -verb 0");
        $cmd_pid = open2(*OUT2, *IN2, "./particle-filter -prior $prior -k $xor $option $nSat -cl $cl -verb 0");
        #print "./particle-filter -prior $prior -k $xor $option $nSat -cl $cl -verb 0\n";
        #print "./one-step -prior $prior -filter particle -k $xor $option $nSat -cl $cl -verb 0\n";
    }
	my $line = <OUT2>;
	($center, $new_sigma, $new_lb, $new_ub) = split ' ', $line;
	
	close IN2;
	close OUT2;
	waitpid($cmd_pid, 0);
    #copy("posterior.dat","posterior$exhaust_cnt.dat") or die "Copy Failed:$!";
    return ($center, $new_sigma, $new_lb, $new_ub);
}

sub updateDist2 {
    my($mu, $sigma, $c, $xor, $nSat) = @_;
    my $new_mu;
    my $new_sigma;
    my $prior;
    my $option;
    
    #Uniform -> Truncated Normal
    if ($sigma > 100) {
        if ($nSat == $c) {
            $prior = "uniform";
            $option = "-nSatGE";
        } else {
            $prior = "uniform";
            $option = "-nSat";
        }
    #Truncated Normal -> Truncated Normal
    } else {
        if ($nSat == $c) {
            $prior = "normal";
            $option = "-nSatGE";           
        } else {
            $prior = "normal";
            $option = "-nSat";           
        }
    }
    my $cmd_pid = open2(*OUT2, *IN2, "./one-step -prior $prior -minsigma normal -mu $mu -sigma $sigma -k $xor $option $nSat -verb 0");
	my $line = <OUT2>;
	($new_mu, $new_sigma) = split ' ', $line;
	
	close IN2;
	close OUT2;
	waitpid($cmd_pid, 0);
    return ($new_mu, $new_sigma);
}

sub getNormFactor {
    my($mu, $sigma, $w) = @_;
    
    if($sigma == 0) {
        return 1;
    }
    my $temp = (erf(($w-$mu)/(sqrt(2)*$sigma))-erf((-$mu)/(sqrt(2)*$sigma)));
    my $k = 2/$temp;
    return $k;
}

sub getBounds {
    my ($mu_prime, $sigma_prime, $w, $cl) = @_;
    my $norm_factor;
    my $ci_factor;
    my $upper;
    my $lower;
    $norm_factor = getNormFactor($mu_prime, $sigma_prime, $w);
    $ci_factor = inv_cdf( ($cl/$norm_factor+1)/2 );
    if(($mu_prime - ($w/2) > 0) && ($mu_prime <= $w)) {
        if($mu_prime + $ci_factor*$sigma_prime < $w) {
            $upper = $mu_prime + $ci_factor*$sigma_prime;
            $lower = $mu_prime - $ci_factor*$sigma_prime;
        } else {
            $upper = $w;
            $lower = $mu_prime + inv_cdf(cdf(($w - $mu_prime)/$sigma_prime) - $cl/$norm_factor)*$sigma_prime;
        }
    } elsif(($mu_prime - ($w/2) <= 0) && ($mu_prime >= 0)) {
        if($mu_prime - $ci_factor*$sigma_prime > 0) {
            $upper = $mu_prime + $ci_factor*$sigma_prime;
            $lower = $mu_prime - $ci_factor*$sigma_prime;
        } else {
            $upper = $mu_prime + inv_cdf($cl/$norm_factor + cdf(-$mu_prime/$sigma_prime))*$sigma_prime;
            $lower = 0;
        }
    } elsif($mu_prime > $w) {
        $upper = $w;
        $lower = $mu_prime + inv_cdf(cdf(($w - $mu_prime)/$sigma_prime) - $cl/$norm_factor)*$sigma_prime;
    } else {
        $upper = $mu_prime + inv_cdf($cl/$norm_factor + cdf(-$mu_prime/$sigma_prime))*$sigma_prime;
        $lower = 0;
    }
    return ($upper, $lower);
}

sub update_prob_table {
    my ($c, $k, $nSat, $cl) = @_;
    
    if ($nSat == 0) {
        
        for my $i (0 .. $k - 1) {
            $array_prob[$i][0] = $array_prob[$i][0] * ( 1 - 1/(2**($k - $i)));
            $array_prob[$i][1] = $array_prob[$i][1];
        }
        
        $array_prob[$k][0] = $array_prob[$k][0] * 0;
        $array_prob[$k][1] = $array_prob[$k][1];
        
        for my $j ($k+1 .. $table_w) {
            $array_prob[$j][0] = $array_prob[$j][0] * 0;
            $array_prob[$j][1] = $array_prob[$j][1] * (1/(2**($j - $k)));
        }

    } elsif ($nSat == $c) {
        for my $i (0 .. $k - 1) {
            $array_prob[$i][0] = $array_prob[$i][0] * 0;
            $array_prob[$i][1] = $array_prob[$i][1] * (1/(2**($k - $i)));
        }
        
        $array_prob[$k][0] = $array_prob[$k][0] * 0;
        $array_prob[$k][1] = $array_prob[$k][1];
        
        for my $j ($k+1 .. $table_w) {
            $array_prob[$j][0] = $array_prob[$j][0] * ( 1 - 1/(2**($j - $k)));
            $array_prob[$j][1] = $array_prob[$j][1];
        }
    } else {
        if ($c > 44) {
            my $center = $k+log2($nSat);
            my $low_index = floor($center-2);
            my $hi_index = ceil($center+2);
            for my $i (0 .. $low_index - 1) {
                $array_prob[$i][0] = $array_prob[$i][0] * 0;
                $array_prob[$i][1] = $array_prob[$i][1] * 0.4;
            }
            
            for my $i ($low_index .. $hi_index) {
                $array_prob[$i][0] = $array_prob[$i][0] * 0.6;
                $array_prob[$i][1] = $array_prob[$i][1];
            }
            
            for my $j ($hi_index + 1 .. $table_w) {
                $array_prob[$j][0] = $array_prob[$j][0] * ( 1 - 1/(2**($j - $k)));
                $array_prob[$j][1] = $array_prob[$j][1];
            }
            
        } else {
            for my $i (0 .. $k - 1) {
                $array_prob[$i][0] = $array_prob[$i][0] * 0;
                $array_prob[$i][1] = $array_prob[$i][1] * (1/(2**($k - $i)));
            }
            
            $array_prob[$k][0] = $array_prob[$k][0] * 0;
            $array_prob[$k][1] = $array_prob[$k][1];
            
            for my $j ($k+1 .. $table_w) {
                $array_prob[$j][0] = $array_prob[$j][0] * ( 1 - 1/(2**($j - $k)));
                $array_prob[$j][1] = $array_prob[$j][1];
            }            
        }
    }
}

sub init_prob_table {
    for my $i (0 .. $table_w) {
        $array_prob[$i][0] = 1;
        $array_prob[$i][1] = 1;
    }
}

sub isZero {
    my $norm_factor_l = 0;
    my $norm_factor_u = 0;
    for my $i (0 .. $table_w) {
        $norm_factor_l = $norm_factor_l + $array_prob[$i][0];
        $norm_factor_u = $norm_factor_u + $array_prob[$i][1];
    }
    if ($norm_factor_l == 0 || $norm_factor_u == 0) {
        return 1;
    } else {
        return 0;
    }
}

sub norm_prob_table {
    my $norm_factor_l = 0;
    my $norm_factor_u = 0;
    for my $i (0 .. $table_w) {
        $norm_factor_l = $norm_factor_l + $array_prob[$i][0];
        $norm_factor_u = $norm_factor_u + $array_prob[$i][1];
    }

    for my $i (0 .. $table_w) {
        $array_prob[$i][0] = $array_prob[$i][0]/($norm_factor_u - $array_prob[$i][1] + $array_prob[$i][0]);
        $array_prob[$i][1] = $array_prob[$i][1]/($norm_factor_l - $array_prob[$i][0] + $array_prob[$i][1]);
    }
}

sub print_prob_table {
    for my $i (0 .. $table_w) {
        printf "%.4f ", $array_prob[$i][0];
    }
    print "\n";
    for my $i (0 .. $table_w) {
        printf "%.4f ", $array_prob[$i][1];
    }
    print "\n";
}

sub getSoundBounds {
    my $low_index=0;
    my $hi_index=64;
    
    for my $i (0 .. $table_w) {
        if ($array_prob[$i][1] > 0) {
            $low_index = $i;
            last;
        } 
    }
    for my $i ($table_w .. 0) {
        if ($array_prob[$i][1] > 0) {
            $hi_index = $i;
            last;
        } 
    }
    my $p = 1;
    while ($p > $cl) {
        if($array_prob[$low_index][1] > $array_prob[$hi_index][1]) {
            $p = $p - $array_prob[$hi_index][1];
            $hi_index--;
        } else {
            $p = $p - $array_prob[$low_index][1];
            $low_index++;
        }
    }
    return $low_index, $hi_index;
}

sub xor_tree {
    my(@a) = @_;
    if (@a == 0) {
        die "empty list in xor_tree";
    } elsif (@a == 1) {
        return $a[0];
    } elsif (@a == 2) {
        return "(xor $a[0] $a[1])";
    } else {
        my $n = scalar(@a);
        my $l1 = floor($n / 2);
        my $l2 = ceil($n / 2);
        die unless $l1 + $l2 == $n;
        my @h2 = @a;
        my @h1 = splice(@h2, $l1);
        die unless @h1 + @h2 == $n;
        my $f1 = xor_tree(@h1);
        my $f2 = xor_tree(@h2);
        return "(xor $f1 $f2)";
    }
}
sub add_xor_constraints_crypto {
    my($filename, $xor_num_vars, $xors, $width, $iter) = @_;
    my $filename_out = "$temp_dir/$iter-$xors-$filename";
    open(my $fh, '<:encoding(UTF-8)', "$temp_dir/org-$filename")
    or die "Could not open file '$temp_dir/org-$filename' $!";
    
    open(my $fh1, '>', "$filename_out");
    
    printf $fh1 "p cnf $numVariables %d\n",$numClauses+$xors;
    
    while( my $line = <$fh>)
    {
        if ($line =~ /^\s*p\s+cnf\s+([0-9]*)\s*([0-9]*)\s*$/) {
        } else {
            print $fh1 "$line";
        }
    }
    close $fh;
    my $sat_flag = 1;

    for my $i (1 .. $xors) {
        my @posns;
        # Commented out: select positions with replacement
        #for my $j (1 .. $num_vars_xor) {
        #    my $pos = int(rand($width));
        #    push @posns, $pos;
        #}
        # First part of a shuffle: select positions without replacement
        #@posns = shuffle @vars;
        #splice(@posns, floor(scalar(@vars)/2));
        #die unless @posns == floor(scalar(@vars)/2);
        for my $j (0 .. scalar(@vars) - 1) {
            if (rand(1) < 0.5) {
                push @posns, $vars[$j];
            }
        }
        if(@posns) {
            my $parity = rand(1) < 0.5 ? "-" : "";
            my $form = join(" ", @posns);
            
            print $fh1 "x$parity$form 0\n";
        } else {
            if (rand(1) < 0.5) {
                $sat_flag = 0;
            }
	} 
    }

    close $fh1;
    if ($sat_flag == 0) {
        $filename_out = "unsat";
    }
    return $filename_out;
}

sub add_xor_constraints_smt {
    my($filename, $width, $num_xor_vars, $k, $iter, $output_name) = @_;
    my $filename_out = "$temp_dir/$iter-$k-$filename";
    open(my $fh, '<:encoding(UTF-8)', "$temp_dir/org-$filename")
    or die "Could not open file '$temp_dir/org-$filename' $!";
    
    open(my $fh1, '>', "$filename_out");
    
    while( my $line = <$fh>)
    {
		if ($line ne "(check-sat)\n") {
			print $fh1 "$line";
		}
    }
    close $fh;
    
    for my $i (1 .. $k) {
        my @posns;
        # Commented out: select positions with replacement
        #for my $j (1 .. $num_vars) {
        #    my $pos = int(rand($width));
        #    push @posns, $pos;
        #}
        # First part of a shuffle: select positions without replacement
        for my $j (0 .. ($width - 1)) {
            if (rand(1) < 0.5) {
                push @posns, $j;
            }
        }
        #@posns = shuffle 0 .. ($width - 1);
        #splice(@posns, $num_xor_vars);
        #die unless @posns == $num_xor_vars;
        if (@posns) {
            my @terms;
            for my $pos (@posns) {
                my $term = "(= #b1 ((_ extract $pos $pos) $output_name))";
                push @terms, $term;
            }
            my $parity = rand(1) < 0.5 ? "true" : "false";
            #my $form = "(xor " . join(" ", @terms, $parity) . ")";
            my $form = xor_tree(@terms, $parity);
            print $fh1 "(assert $form)\n";
        }
    }
    print $fh1 "(check-sat)\n";
    print $fh1 "(get-value ($output_name))\n";
    close $fh1;
    return $filename_out;
}
sub add_neq_constraints_smt {
    my($filename_cons, $filename, $solns, $ce, $iter, $xors, $width,$output_name) = @_;
    my $filename_out = "$temp_dir/$iter-$xors-$solns-$filename";
    open(my $fh, '<:encoding(UTF-8)', $filename_cons)
    or die "Could not open file '$filename' $!";
    
    open(my $fh1, '>', "$filename_out");
    
    while( my $line = <$fh>)
    {
        if ($line eq "(check-sat)\n") {
	    printf $fh1 "(assert (not (= $output_name %s)))\n", $ce;
	    last;
        }
        else {
            print $fh1 "$line";
        }
    }
    close $fh;
    
    print $fh1 "(check-sat)\n";
    print $fh1 "(get-value ($output_name))\n";
    close $fh1;
    if(!$save_files) {
        unlink $filename_cons;
    }
    return $filename_out;
}


sub MBoundExhaustUpToC_crypto {
    my($filename, $width, $xor_num_vars, $xors, $c, $iter) = @_;
    my $solns = 0;
    
    my $filename_cons = add_xor_constraints_crypto($filename, $xor_num_vars, $xors, $width, $iter);
    if ($filename_cons eq "unsat") {
	return 0;
    } else {
    run_solver($filename_cons, $c, $solver);
    my $sat;
    my $unsat;
    if($solver eq "cryptominisat5") {
		$unsat = "s UNSATISFIABLE\n";
		$sat = "s SATISFIABLE\n";
	} elsif ($solver eq "cryptominisat2") {
		$unsat = "c UNSATISFIABLE\n";
		$sat = "c SATISFIABLE\n";
	}
    while (my $line = <OUT>) {
        if ($line eq $unsat) {
            last;
        } elsif ($line eq $sat) {
            $solns++;
        } elsif ($line =~ /^cr ([0-9]*)$/) {
            
        } else {
            print "Unexpected cryptominisat result: $line\n";
            die;
        }
    }
    end_solver();
    }
    if(!$save_files) {
        unlink $filename_cons;
    }
    return $solns;
}

sub MBoundExhaustUpToC_z3_batch {
    my($filename, $width, $num_xor_vars, $k, $c, $iter, $output_name) = @_;
    my $solns = 0;
    my $filename_cons = add_xor_constraints_smt($filename, $width, $num_xor_vars, $k, $iter, $output_name);
    
    while ($solns < $c) {
        run_solver($filename_cons, $c, $solver);
        my $line = <OUT>;
        my $ce;
        if ($line eq "unsat\n") {
            $line = <OUT>;
            last;
        } elsif ($line eq "sat\n") {
            $solns++;
            $line = <OUT>;
        } else {
            print "Unexpected Z3 result: $line\n";
            die;
        }
        if ($width % 4 == 0) {
            if ($line =~ /^\(\($output_name (#x[0-9a-fA-F]*)\)\)$/) {
                $ce = $1;
                $filename_cons = add_neq_constraints_smt($filename_cons, $filename, $solns, $ce, $iter, $k, $width, $output_name);
			}
		} else {
			if ($line =~ /^\(\($output_name (#b[0-9]*)\)\)$/)
			{
				$ce = $1;
				$filename_cons = add_neq_constraints_smt($filename_cons, $filename, $solns, $ce, $iter, $k, $width, $output_name);
			}
		}
		end_solver();
	}
	if(!$save_files) {
        unlink $filename_cons;
    }
	return $solns;
}

sub MBoundExhaustUpToC_smt_batch {
    my($filename, $width, $num_xor_vars, $k, $c, $iter, $output_name) = @_;
    my $solns = 0;
    my $filename_cons =
      add_xor_constraints_smt($filename, $width, $num_xor_vars, $k, $iter,
			      $output_name);

    while ($solns < $c) {
        run_solver($filename_cons, $c, $solver);
	my $ce;
	my $seen_sat = 0;
	my $first_line = <OUT>;
	if ($first_line eq "unsat\n") {
	    last;
	} elsif ($first_line eq "sat\n") {
	    $seen_sat = 1;
	} else {
	    die "Unexpected solver output line: $first_line";
	}
	while (my $line = <OUT>) {
            if ($line =~ /^\(\($output_name (#x[0-9a-fA-F]*)\)\)$/) {
		die "Unexpected hex bitvector" if $width % 4;
		$ce = $1;
	    } elsif ($line =~ /^\(\($output_name (#b[0-9]*)\)\)$/) {
		$ce = $1;
	    } elsif ($line =~ /\($output_name (\(_ bv\d+ \d+\))\)/) {
		$ce = $1;
	    }
	}
	if ($seen_sat and not defined $ce) {
	    die "Failed to parse satisfying assignment to $output_name ($filename_cons)";
	}
	$solns++;
	$filename_cons =
	  add_neq_constraints_smt($filename_cons, $filename, $solns,
				  $ce, $iter, $k, $width, $output_name);
	end_solver();
    }
    if(!$save_files) {
        unlink $filename_cons;
    }
    return $solns;
}


sub MBoundExhaustUpToC_z3_inc {
    my($width, $num_vars, $xors, $c, $output_name) = @_;
    my $solns = 0;
    print IN "(push 1)\n";
    for my $i (1 .. $xors) {
        my @posns;
        # Commented out: select positions with replacement
        #for my $j (1 .. $num_vars) {
        #    my $pos = int(rand($width));
        #    push @posns, $pos;
        #}
        # First part of a shuffle: select positions without replacement
        @posns = shuffle 0 .. ($width - 1);
        splice(@posns, $num_vars);
        die unless @posns == $num_vars;
        my @terms;
        for my $pos (@posns) {
            my $term = "(= #b1 ((_ extract $pos $pos) $output_name))";
            push @terms, $term;
        }
        my $parity = rand(1) < 0.5 ? "true" : "false";
        #my $form = "(xor " . join(" ", @terms, $parity) . ")";
        my $form = xor_tree(@terms, $parity);
        print IN "(assert $form)\n";
    }
      
    while ($solns < $c) {
        print IN "(check-sat)\n";
        my $line = <OUT>;
        my $ce;
        
        if ($line eq "unsat\n") {
            last;
        } elsif ($line eq "sat\n") {
            $solns++;
            print IN "(get-value ($output_name))\n";
            my $line2;
            $line2 = <OUT>;
            if ( $width % 4 == 0 ) {
                if ( $line2 =~ /^\(\($output_name #x([0-9a-fA-F]*)\)\)$/ ) {
                    $ce = $1;
                    printf IN "(assert (not (= $output_name #x%s)))\n", $ce;
				} else {
					print "Unexpected Z3 result: $line2\n";
					die;
				}
			} else {
				if ( $line2 =~ /^\(\($output_name #b([0-9]*)\)\)$/ ) {
					$ce = $1;
					printf IN "(assert (not (= $output_name #b%s)))\n", $ce;
				} else {
					print "Unexpected Z3 result: $line2\n";
					die;
				}
			}
		} else {
			print "Unexpected Z3 result: $line\n";
			die;
		}
	}
	print IN "(pop 1)\n";
	return $solns;
}

sub ComputeCandK {
    my ($mu, $sig, $c_max, $numVariables, $thres) = @_;
    my $c = ceil(((2**$sig+1)/(2**$sig-1))**2);
    my $k = floor($mu - (log2($c)*0.5));
    if ($thres == 0) {
		# Special case: threshold = 0 ==> disable approximation
		$k = 0;
	}
    if ($k <= 0) {
        $k = 0;
        $c = $c_max;
    }
    return ($c, $k);
}

sub log2 {
    my $n = shift;
    return log($n)/log(2);
}

sub erf {
    my($x) = @_;
    # constants
    my $a1 =  0.254829592;
    my $a2 = -0.284496736;
    my $a3 =  1.421413741;
    my $a4 = -1.453152027;
    my $a5 =  1.061405429;
    my $p  =  0.3275911;
    
    # Save the sign of x
    my $sign = 1;
    if ($x < 0) {
        $sign = -1;
    }
    $x = abs($x);
    
    # A&S formula 7.1.26
    my $t = 1.0/(1.0 + $p*$x);
    my $y = 1.0 - ((((($a5*$t + $a4)*$t) + $a3)*$t + $a2)*$t + $a1)*$t*exp(-($x*$x));
    
    return $sign*$y;
}

sub RationalApproximation {
    my($t) = @_;
    my @c = (2.515517, 0.802853, 0.010328);
    my @d = (1.432788, 0.189269, 0.001308);
    return $t - (($c[2]*$t + $c[1])*$t + $c[0]) / ((($d[2]*$t + $d[1])*$t + $d[0])*$t + 1.0);
}

sub inv_cdf {
    my($p) = @_;
    if ($p <= 0.0 || $p >= 1.0) {
        die "Invalid inv_cdf input\n";
    }
    
    if ($p < 0.5) {
        return -RationalApproximation(sqrt(-2.0*log($p)) );
    } else {
        return RationalApproximation(sqrt(-2.0*log(1.0 - $p)) );
    }
}

sub cdf {
    my($x) = @_;
    
    my $a1 =  0.254829592;
    my $a2 = -0.284496736;
    my $a3 =  1.421413741;
    my $a4 = -1.453152027;
    my $a5 =  1.061405429;
    my $p  =  0.3275911;
    
    # Save the sign of x
    my $sign = 1;
    if ($x < 0) {
        $sign = -1;
    }
    $x = abs($x)/sqrt(2.0);
    
    my $t = 1.0/(1.0 + $p*$x);
    my $y = 1.0 - ((((($a5*$t + $a4)*$t) + $a3)*$t + $a2)*$t + $a1)*$t*exp(-($x*$x));
    
    return 0.5*(1.0 + $sign*$y);
}

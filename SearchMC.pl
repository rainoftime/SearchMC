#!/usr/bin/perl

use strict;
#use warnings;
use Fcntl qw(SEEK_SET SEEK_CUR SEEK_END);

use POSIX 'floor', 'ceil';
use IPC::Open2;
use List::Util 'shuffle';
use Time::HiRes qw(time);
use File::Basename;
use Scalar::Util qw(looks_like_number);
use Getopt::Long;

my $meanSize = 640;
my $sigmaSize = 120;
my $cryptominisat = "./cryptominisat4";
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

my $table_w;
my $numVariables;
my $numClauses;
my $c_max = 15;

## Options
my $cl;
my $thres;

my $mode = "batch";
my $verbose = 0;
my $save_CNF_files = '';
my $xor_num_vars;
my $help = '';
my $input_type = "cnf";
my $proj_flag = '';
my $output_name;

GetOptions ("thres=f" => \$thres,
"cl=f"   => \$cl,
"mode=s"   => \$mode,
"verbose=i"  => \$verbose,
"input_type=s" => \$input_type,
"save_CNF_files" => \$save_CNF_files,
"xor_num_vars=i" => \$xor_num_vars,
"output_name=s" => \$output_name,
"help|?" => \$help)
or die("Error in command line arguments\n");

die "No input file!\n"
unless @ARGV == 1;

my $filename = $ARGV[0];
my $base_filename = basename($filename);

mkdir ($temp_dir) unless(-d $temp_dir);

my $start = time();

if($input_type eq "smt") {
    convert_smt_to_cnf($filename);
    $filename = "./$base_filename.cnf";
    rename "./output_0.cnf", $filename;
    $base_filename = basename($filename);
}
    
check_options();

$table_w = 64;
my $delta = $table_w;
#$cl = (sqrt(($cl*100)**2-25)+5)/100;

## initial round: uniform -> truncated normal
$mu = $table_w / 2;
$sigma = 100000000;
$k = sprintf("%.0f", $mu);
$c = 1;

my $sub_start = time();

my $nSat = MBoundExhaustUpToC($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt);
$sat_cnt++;
$exhaust_cnt++;

($mu_prime, $sigma_prime) = updateDist($mu, $sigma, $c, $nSat);

($ub, $lb) = getBounds($mu_prime,$sigma_prime,$table_w,$cl);

my $sub_end = time();

if ($verbose == 1) {
    print "$exhaust_cnt: Old Mu = $mu, Old Sigma = $sigma, nSat = $nSat, k = $k, c = $c\n";
    print "$exhaust_cnt: New Mu = $mu_prime, New Sigma = $sigma_prime\n";
    printf "$exhaust_cnt: Lower Bound = %.4f, Upper Bound = %.4f\n",$lb, $ub;
    printf("$exhaust_cnt: Running Time = %.4f\n", $sub_end - $sub_start);
}

$mu = $mu_prime;
$sigma = $sigma_prime;
$delta = $ub - $lb;

## rest round: truncated normal -> truncated normal
while ($delta > $thres)
{
    $sub_start = time();
    ($c ,$k) = ComputeCandK($mu, $sigma, $c_max, $numVariables);
    if($mode eq "inc") {
        read_file_inc($filename);
        $nSat = MBoundExhaustUpToC($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt);
        
    } else {
        $nSat = MBoundExhaustUpToC($base_filename, $numVariables, $xor_num_vars, $k, $c, $exhaust_cnt);
    }
        
    $exhaust_cnt++;
    if($nSat == $c) {
        $sat_cnt=$sat_cnt+$nSat;
    } else {
        $sat_cnt=$sat_cnt+$nSat+1;
    }
    
    if ($k == 0 ) {
        print "Result: Exact Influence = $nSat\n";
        last;
    } else {
        ($mu_prime, $sigma_prime) = updateDist($mu, $sigma, $c, $nSat);
        while($mu_prime == -1) {
            $nSat = MBoundExhaustUpToC($base_filename, $numVariables, $k, $c, $exhaust_cnt);
            $exhaust_cnt++;
            if($nSat == $c) {
                $sat_cnt=$sat_cnt+$nSat;
            } else {
                $sat_cnt=$sat_cnt+$nSat+1;
            }
            ($mu_prime, $sigma_prime) = updateDist($mu, $sigma, $c, $nSat);
        }
        ($ub, $lb) = getBounds($mu_prime,$sigma_prime,$table_w,$cl);
        $sub_end = time();
        if ($verbose == 1) {
            printf "$exhaust_cnt: Old Mu = %.4f, Old Sigma = %.4f, nSat = $nSat, k = $k, c = $c\n", $mu, $sigma;
            printf "$exhaust_cnt: New Mu = %.4f, New Sigma = %.4f\n", $mu_prime, $sigma_prime;
            printf "$exhaust_cnt: Lower Bound = %.4f, Upper Bound = %.4f\n",$lb, $ub;
            printf("$exhaust_cnt: Running Time = %.4f\n", $sub_end - $sub_start);
        }
        $mu = $mu_prime;
        $sigma = $sigma_prime;
        $delta = $ub - $lb;
    }
}
if($save_CNF_files == 0) {
    unlink "$temp_dir/org-$base_filename";
}
my $end = time();

if ($k == 0 ) {
    print "Result: Filename = $base_filename\n";
    print "Result: #ExhaustUptoC Query = $exhaust_cnt\n";
    print "Result: #Sat Query = $sat_cnt\n";
    printf("Result: Running Time = %.4f\n", $end - $start);
} else {
    printf "%.4f %.4f\n",$lb,$ub;
    printf "Result: Lower Bound = %.4f\n",$lb;
    printf "Result: Upper Bound = %.4f\n",$ub;
    print "Result: Filename = $base_filename\n";
    print "Result: #ExhaustUptoC Query = $exhaust_cnt\n";
    print "Result: #Sat Query = $sat_cnt\n";
    printf("Result: Running Time = %.4f\n", $end - $start);
}

sub convert_smt_to_cnf {
    my($filename) = @_;
    my $converter_pid = open2(*OUT, *IN, "./stp-2.1.2 -p --disable-simplify --disable-cbitp --disable-equality -a -w --output-CNF --minisat $filename");
    my $num;
    while(my $line = <OUT>) {
        if ($line =~ /^VarDump: $output_name bit ([0-9]*) is SAT var ([0-9]*)$/) {
            $num = $2;
            push @vars, $num;
        }
    }
    close IN;
    close OUT;
    waitpid($converter_pid, 0);
}

sub check_options {
    if ($help)
    {
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
        -mode=<solver mode>: solver mode; batch (default), inc (not supported)\n
        -save_CNF_files : store all CNF files\n";
        last;
    }
    if ($cl && $thres) {
    
    } else {
        die "cl and thres values needed\n"
    }
    if ($mode ne "batch") {
        die "Invalid mode\n";
    }

    if($mode eq "batch") {
        read_file_batch($filename);
    } else {
        die "Invalid mode\n";
    }
    
    if($xor_num_vars) {
    } else {
        $xor_num_vars = floor(scalar(@vars)/2);
    }
}

sub read_file_batch {
    my($filename) = @_;
    ## read input file
    open(my $fh1, '<:encoding(UTF-8)', $filename)
    or die "Could not open file '$filename' $!";
    
    open(my $fh2, '>', "$temp_dir/org-$base_filename");
    
    while(my $line = <$fh1>) {
        if ($line =~ /^p cnf ([0-9]*) ([0-9]*)$/) {
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
		} else {
            print $fh2 "$line";
        }
    }
    close $fh1;
    close $fh2;
}

sub run_solver {
    my($filename, $c) = @_;
    $solver_pid = open2(*OUT, *IN, "$cryptominisat --autodisablegauss=0 --printsol=0 --maxsol=$c --verb=0 $filename");
}

sub end_solver {
    close IN;
    close OUT;
    waitpid($solver_pid, 0);
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

sub updateDist {
    my($mu, $sigma, $c, $nSat) = @_;
    my $new_mu;
    my $new_sigma;
    if ($sigma > 1000) {
        if ($nSat == 0) {
            $new_mu = 13.2260;
            $new_sigma = 11.1464;
        } else {
            $new_mu = 50.0896;
            $new_sigma = 11.4412;
        }
        
        return ($new_mu, $new_sigma);
    } else {
        my @resultarray_mu;
        my @resultarray_sigma;
        my $filename_mu;
        my $filename_sigma;
        
        if ($nSat == $c) {
            $filename_mu = "./dist_tables/mu$nSat-more.txt";
            $filename_sigma = "./dist_tables/sig$nSat-more.txt";
        } else {
            $filename_mu = "./dist_tables/mu$nSat.txt";
            $filename_sigma = "./dist_tables/sig$nSat.txt";
        }
        open(my $fh1, '<:encoding(UTF-8)', $filename_mu)
        or die "Could not open file '$filename_mu' $!";
        open(my $fh2, '<:encoding(UTF-8)', $filename_sigma)
        or die "Could not open file '$filename_sigma' $!";
        
        for(my $i=0; $i < $meanSize; $i++) {
            seek($fh1,0,SEEK_CUR);
            seek($fh2,0,SEEK_CUR);
            my $lines1 = <$fh1>;
            my $lines2 = <$fh2>;
            my @linearray1 = split ' ', $lines1;
            my @linearray2 = split ' ', $lines2;
            push(@resultarray_mu, @linearray1);
            push(@resultarray_sigma, @linearray2);
        }
        
        my $index1 = sprintf("%.1f", $mu-0.05)*10;
        my $index2 = sprintf("%.1f", $sigma-0.05)*10;
        
        my $w1 = 10*($mu-sprintf("%.1f", $mu-0.05));
        my $w2 = 10*($sigma-sprintf("%.1f", $sigma-0.05));
        my $lu_mu = $resultarray_mu[$sigmaSize*$index1+$index2];
        my $ru_mu = $resultarray_mu[$sigmaSize*$index1+$index2+1];
        my $ll_mu = $resultarray_mu[$sigmaSize*($index1+1)+$index2];
        my $rl_mu = $resultarray_mu[$sigmaSize*($index1+1)+$index2+1];
        my $lu_sigma = $resultarray_sigma[$sigmaSize*$index1+$index2];
        my $ru_sigma = $resultarray_sigma[$sigmaSize*$index1+$index2+1];
        my $ll_sigma = $resultarray_sigma[$sigmaSize*($index1+1)+$index2];
        my $rl_sigma = $resultarray_sigma[$sigmaSize*($index1+1)+$index2+1];
        
        if (looks_like_number($lu_mu) && looks_like_number($ru_mu) && looks_like_number($ll_mu) && looks_like_number($rl_mu) &&
            looks_like_number($lu_sigma) && looks_like_number($ru_sigma) && looks_like_number($ll_sigma) && looks_like_number($rl_sigma)) {
                $new_mu = (1-$w1)*($w2*$ru_mu+(1-$w2)*$lu_mu)+($w1)*($w2*$rl_mu+(1-$w2)*$ll_mu);
                $new_sigma = (1-$w1)*($w2*$ru_sigma+(1-$w2)*$lu_sigma)+($w1)*($w2*$rl_sigma+(1-$w2)*$ll_sigma);
            } else {
                $new_mu = -1;
                $new_sigma = -1;
            }
        close $fh1 or die "Unable to close file: $!";
        close $fh2 or die "Unable to close file: $!";
        return ($new_mu, $new_sigma);
    }
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

sub add_xor_constraints {
    my($filename, $xor_num_vars, $xors, $width, $iter) = @_;
    my $filename_out = "$temp_dir/$iter-$xors-$filename";
    open(my $fh, '<:encoding(UTF-8)', "$temp_dir/org-$filename")
    or die "Could not open file '$temp_dir/org-$filename' $!";
    
    open(my $fh1, '>', "$filename_out");
    
    printf $fh1 "p cnf $numVariables %d\n",$numClauses+$xors;
    
    while( my $line = <$fh>)
    {
        if ($line =~ /^p cnf ([0-9]*) ([0-9]*)$/) {
        } else {
            print $fh1 "$line";
        }
    }
    close $fh;

    for my $i (1 .. $xors) {
        my @posns;
        # Commented out: select positions with replacement
        #for my $j (1 .. $num_vars_xor) {
        #    my $pos = int(rand($width));
        #    push @posns, $pos;
        #}
        # First part of a shuffle: select positions without replacement
        @posns = shuffle @vars;
        splice(@posns, floor(scalar(@vars)/2));
        die unless @posns == ceil(scalar(@vars)/2);
        my @terms;
        for my $pos (@posns) {
            my $term = $pos;
            push @terms, $term;
        }
        my $parity = rand(1) < 0.5 ? "-" : "";
        my $form = join(" ", @terms);
        
        print $fh1 "x$parity$form 0\n";
    }

    close $fh1;
    return $filename_out;
}


sub MBoundExhaustUpToC {
    my($filename, $width, $xor_num_vars, $xors, $c, $iter) = @_;
    my $solns = 0;
       
    my $filename_cons = add_xor_constraints($filename, $xor_num_vars, $xors, $width, $iter);
    
    run_solver($filename_cons, $c);
    while (my $line = <OUT>) {
        if ($line eq "s UNSATISFIABLE\n") {
            last;
        } elsif ($line eq "s SATISFIABLE\n") {
            $solns++;
        } elsif ($line =~ /^cr ([0-9]*)$/) {

		} else {
            print "Unexpected cryptominisat result: $line\n";
            die;
        }
    }
    
    end_solver();
   
    if($save_CNF_files == 0) {
        unlink $filename_cons;
    }

    return $solns;
}

sub ComputeCandK {
    my ($mu, $sigma, $c_max, $numVariables) = @_;
    my $c = ceil(((2**$sigma+1)/(2**$sigma-1))**2);
    #my $c = ceil((2**(2*$sigma)+1)/(2**(2*$sigma)-1));
    if($c > $c_max) {
        $c = $c_max;
    }
    my $k = floor($mu - (log2($c)/2));
    if ($k <= 0) {
        $k = 0;
        $c = 2**$numVariables + 1;
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
    my @c = {2.515517, 0.802853, 0.010328};
    my @d = {1.432788, 0.189269, 0.001308};
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
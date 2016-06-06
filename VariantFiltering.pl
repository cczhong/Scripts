#!/usr/bin/perl -w
use strict;
use Getopt::Long;
use Text::NSP::Measures::2D::Fisher::left;


my $tumor_vcf;      # the cfDNA file
my $control_vcf;    # the second file
my $info_col = 7;   # the information column (usually it is 7)
my $fmt_col = 8;    # the format column (usually it is 8)
my $somatic = 0;    # only calling somatic mutation
my $impure = 0;     # whether to estimate purity on the sample
my $dp_frac = 0.01;  # depth of coverage fraction
my $fs_pv = 0.01;    # Fisher's exact test p-value cutoff
my $qual = 1500;    # QUAL field filter
my $fs = 70;        # FS field filter
my $qd = 0.8;       # QD field filter
my $mq = 40;        # MQ field filter
my $help = 0;       # print help information
my $out;            # the output file

GetOptions (
  "tumor=s" => \$tumor_vcf,
  "control=s" => \$control_vcf,
  "info_col=s" => \$info_col,
  "fmt_col=s" => \$fmt_col,
  "somatic" => \$somatic,
  "impure" => \$impure,
  "dp_frac=s" => \$dp_frac,
  "fs_pv=s" => \$fs_pv,
  "QUAL=s" => \$qual,
  "FS=s" => \$fs,
  "QD=s" => \$qd,
  "MQ=s" => \$mq,
  "out=s" => \$out,
  "help" => \$help
) or die("Error in command line arguments\n");

if($help || !$tumor_vcf || !defined $out)  {
  print "Function: perform cfDNA analysis pipeline.\n";  
  print "Usage: perl VariantFiltering.pl --tumor=[FILE1] --control=[FILE2] --out=[OUTFILE]\n";
  print "\t--tumor:\tthe VCF file contains the SNPs called from tumor sample\n";
  print "\t--control:\tthe VCF file contains the SNPs called from control sample;\n";
  print "\t\t\tmultiple files separated by colon \":\"\n";
  print "\t--somatic:\tonly output somatic mutations; default NO\n";
  print "\t--impure:\tassume the sample is impure and perform purity filtering; default NO\n";
  print "\t--dp_frac:\tdepth of coverage fraction to be filtered; default 0.01\n";
  print "\t--fs_pv:\tFisher's exact test p-value for filtering impure variants; default 0.01\n";
  print "\t--info_col:\tthe information column in the VCF file, the column looks like \"AC=1;AF=0.500;AN=2;\"...; default 7\n";
  print "\t--fmt_col:\tthe format column in the VCF file, the column looks like \"GT:AD:DP:GQ:PL\"...; default 8\n";
  print "\t--QUAL:\t\tfilter for QUAL field; default 1500\n";
  print "\t--FS:\t\tfilter for FS field; default 70\n";
  print "\t--QD:\t\tfilter for QD field; default 0.8\n";
  print "\t--MQ:\t\tfilter for MQ field; default 40\n";
  print "\t--out:\t\tthe file that output the results\n";
  print "\t--help:\t\tprint this help information\n";
  exit;
}

# identifying the VAF (variant allele frequency) of the germ line mutations 
my %tumor_norm_hash;
my %tumor_muta_hash;
my %tumor_qual_hash;
my %tumor_fs_hash;
my %tumor_qd_hash;
my %tumor_mq_hash;
my %tumor_info_hash;
my @tumor_coverage_array;
open my $TIN, "<$tumor_vcf" or die "Cannot open tumor VCF file: $!\n";
while(<$TIN>) {
  next if(/^\#/);  
  chomp;
  my $line = $_;
  my @decom = split /\s+/, $_;
  my @decom2 = split /\:/, $decom[$fmt_col];
  my $snp_id = $decom[0] . '_' . $decom[1] . '_' . $decom[3] . '_' . $decom[4];
  $tumor_info_hash{$snp_id} = $line;
  $tumor_qual_hash{$snp_id} = $decom[5];
  if($line =~ /FS\=(.*?)\;/)  {
    $tumor_fs_hash{$snp_id} = $1;
  }
  if($line =~ /QD\=(.*?)\;/)  {
    $tumor_qd_hash{$snp_id} = $1;
  }
  if($line =~ /MQ\=(.*?)\;/)  {
    $tumor_mq_hash{$snp_id} = $1;
  }
  my $ad_idx;
  my $dp_idx;
  for(my $i = 0; $i < scalar(@decom2); ++ $i)   {
      if($decom2[$i] eq "AD")    {
          $ad_idx = $i;
      }   elsif($decom2[$i] eq "DP") {
          $dp_idx = $i;
      }
  }
  if(!defined $ad_idx || !defined $dp_idx)    {
      #print "Warning: cannot identify coverage information, skip line...\n";
      #print "Line info: $line\n";      
      next;
  }

  my @decom3 = split /\:/, $decom[$fmt_col + 1];
  my $snp_norm = 0;
  my $snp_muta = 0;
  if($decom3[$ad_idx] =~ /(\d+)\,(\d+)/)  {
    $snp_norm = $1; $snp_muta = $2;
  }                
  if($snp_norm + $snp_muta >= 0)  {
    $tumor_norm_hash{$snp_id} = $snp_norm; $tumor_muta_hash{$snp_id} = $snp_muta;
    push @tumor_coverage_array, $snp_norm + $snp_muta;
  }  
}
close $TIN;


# estimate dp cutoff for cfDNA sample
@tumor_coverage_array = sort @tumor_coverage_array;
my $total_dp = 0;
foreach(@tumor_coverage_array)  {$total_dp += $_;}
my $tumor_dp_cutoff;
my $acc_dp = 0;
foreach(@tumor_coverage_array)  {
  $acc_dp += $_;
  if($acc_dp / $total_dp > $dp_frac)  {
    $tumor_dp_cutoff = $_;  last;  
  }
}

# estimate the sample purity
my %vaf;
my $tumor_read_normal = 0;
my $tumor_read_mutate = 0;
foreach(sort keys %tumor_norm_hash) {
  if(exists $tumor_muta_hash{$_} && 
    $tumor_norm_hash{$_} + $tumor_muta_hash{$_} >= $tumor_dp_cutoff
  )  {
    my $v = $tumor_muta_hash{$_} / ($tumor_norm_hash{$_} + $tumor_muta_hash{$_});
    $tumor_read_normal += $tumor_norm_hash{$_};
    $tumor_read_mutate += $tumor_muta_hash{$_};
    $v = sprintf "%.2f", $v;
    $vaf{$v} += 1;
  }
}
my $max_count = 0; my $max_x; my @all_sums;
for(my $x = 0; $x < 0.50; $x += 0.01) {
  my $sum_count = 0;
  my $p;
  $p = $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  $p = 2 * $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  $p = 0.50 - $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  $p = 0.50 + $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  $p = 1 - 2 * $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  $p = 1 - $x; $sum_count += $vaf{$p} if exists $vaf{$p};
  push @all_sums, $sum_count;
  if($sum_count > $max_count) {
    $max_count = $sum_count; $max_x = $x;
  }
}

# perform criteria-based filtering
foreach(sort keys %tumor_info_hash) {
  my $id = $_;
  if(exists $tumor_norm_hash{$id} && exists $tumor_muta_hash{$id} &&
      $tumor_norm_hash{$id} + $tumor_muta_hash{$id} >= $tumor_dp_cutoff &&
      exists $tumor_qual_hash{$id} && $tumor_qual_hash{$id} >= $qual &&
      exists $tumor_fs_hash{$id} && $tumor_fs_hash{$id} <= $fs &&
      exists $tumor_qd_hash{$id} && $tumor_qd_hash{$id} >= $qd &&
      exists $tumor_mq_hash{$id} && $tumor_mq_hash{$id} >= $mq
  )  {
    if($impure)  {
      my $n11 = $tumor_read_normal; my $n12 = $tumor_read_mutate;
      my $n21 = $tumor_norm_hash{$id}; my $n22 = $tumor_muta_hash{$id};
      my $n1p = $n11 + $n12; my $np1 = $n11 + $n21; my $npp = $n11 + $n12 + $n21 + $n22;
      my $left_value = calculateStatistic( 
          n11=>$n11, n1p=>$n1p, np1=>$np1, npp=>$npp
      );
      if($left_value < $fs_pv)  {
        delete $tumor_info_hash{$id};
      }
    }
  } else  {
    delete $tumor_info_hash{$id};
  }
}

# perform germline variants filtering
if($somatic)  {
  my @decom = split /\:/, $control_vcf;
  foreach(@decom) {
    my $file = $_;
    open my $IN, "<$file" or die "Cannot open germline VCF file: $!\n";
    while(<$IN>) {
      next if(/^\#/);  
      chomp;
      my @decom = split /\s+/, $_;
      my $snp_id = $decom[0] . '_' . $decom[1] . '_' . $decom[3] . '_' . $decom[4];
      delete $tumor_info_hash{$snp_id} if exists $tumor_info_hash{$snp_id};
    }
    close $IN;
  }
}

# output the remaining variants
open my $OUT, ">$out" or die "Cannot create output VCF file: $!\n";
foreach(sort keys %tumor_info_hash) {
  print $OUT "$tumor_info_hash{$_}\n";
}
close $OUT;



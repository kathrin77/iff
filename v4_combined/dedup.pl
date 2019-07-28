#!/usr/bin/perl

use strict;
use warnings;

=pod

=head1 METADATA DEDUPLICATION FOR IFF RECORDS

=head2 NAME

dedup.pl - Perl script for data deduplication by SRU service

=head2 DESCRIPTION

Usage: dedup.pl [-c config] [-f file] [-h]

Parameters:

-c    desired SRU / matching configuration (gvi or swissbib)

-f    input data file (.csv)

-h    help text

More information on script in Readme on GitHub.

=head2 AVAILABILITY 

This script is shared and documented on GitHub: L<https://github.com/kathrin77/iff>

=head2 AUTHOR

Kathrin Heim, July 2019 (kathrin.heim@gmail.com)

=head2 SEE ALSO

XML-Parser: L<XML::LibXML|https://metacpan.org/pod/XML::LibXML>

XPath Module: L<XML::LibXML::XPathContext|https://metacpan.org/pod/XML::LibXML::XPathContext>

CSV Module: L<Text::CSV|https://metacpan.org/pod/Text::CSV>

Timer: L<Time::HiRes|https://metacpan.org/pod/Time::HiRes>

Config: L<Config::Tiny|https://metacpan.org/pod/Config::Tiny>

Command Line Options: L<Getopt::Std|https://metacpan.org/pod/Getopt::Std>

Debugging: L<Data::Dumper::Names|https://metacpan.org/pod/Data::Dumper::Names>

=cut

use Time::HiRes qw ( time );
use Text::CSV;
use String::Util qw(trim);
use Config::Tiny;
use Data::Dumper::Names;
use URI::Escape;
use XML::LibXML;
use XML::LibXML::XPathContext;
binmode( STDOUT, ":utf8" );
use Encode;
use Getopt::Std;

# ----
# DECLARATION OF GLOBAL VARIABLES
# ----

# start timer: 
my $starttime = time();

# create a config file: 
my $config = Config::Tiny->new;

# get input options from command line:
my %opts;
my $datafile;
getopts('c:f:h', \%opts);

if (defined $opts{h} || (! (defined $opts{c} | defined $opts{f} ))) {
    print_help();
    exit(1);
}

if (defined $opts{c}) {
	my $conf_name = $opts{c} .'.conf';
    if ($conf_name =~ /[swissbib|gvi]\.conf/) {
    	$config = Config::Tiny->read($conf_name);     	
    } else {
    	print_help();
    	exit;
    }
}
if (defined $opts{f}) {
	$datafile = $opts{f};
} 

# set global config values:
my $base_url  = build_base_url($config);
my $window    = $config->{sru}->{max_records};
my $m_safe    = $config->{match}->{safe};
my $GVI       = $config->{net}->{GVI};

# set import and export variables:
my $line;            # a data line from csv file
my @export;          # array for export data
my @bestmatch;       # array for best matching record

# initialize counters, set counters to zero:
my %ctr = map { $_ => 0; } qw(line ignore journal notfound nohits found unsafe iffnotfound replace reimport best iffonly);

# build subject hash
my %subj_hash = build_subject_table();

# get blacklisted titles
my $blacklist = list_of_journals();

# create a new csv object
my $csv = Text::CSV->new( { binary => 1, sep_char => ";" } ) or die "Cannot use CSV: " . Text::CSV->error_diag();
  
# create file handles and open files
open my $fh_in,     "<",                $datafile       or die "$datafile: $!";
open my $fh_report, ">:encoding(utf8)", "report.txt"    or die "report.txt: $!";
open my $fh_out,    ">",                "export.csv"    or die "export.csv: $!";
open my $fh_XML,    ">:encoding(utf8)", "metadata.xml"  or die "metadata.xml: $!";

# print xml header
print $fh_XML '<?xml version="1.0"?><data>';

# --------------------------
# READ INPUT FILE AND TREAT EACH LINE
# --------------------------

while ( $line = $csv->getline($fh_in) ) {

    $ctr{line}++;
    print_rep_header( $fh_report, $ctr{line}, $opts{c});
    print_progress($ctr{line});
    $bestmatch[0] = 0; 
    my ( $aut1, $aut2, $tit, $stit, $v1, $v2, $isbn, $pag, $mat, $add, $loc, 
    	$callno, $place, $pub, $year, $code1, $code2, $code3 ) = get_vars_from_csv($line);      
 
    if ($ctr{line} == 1) {
    	$aut1 = remove_bom($aut1);
    }

    # ------
    # normalize the data:
    # ------
    my %norm; 			# hash for all needed, normalized values
    my %flag;           # hash for all needed flag values
    
    ( $norm{isbn1}, $norm{isbn2}, $flag{isbn1}, $flag{isbn2} )                    = normalize_isbn($isbn);
    ( $norm{aut1}, $flag{aut1} )                                                  = normalize_author($aut1);
    ( $norm{aut2}, $flag{aut2} )                                                  = normalize_author($aut2);
	$norm{tit}                                                                    = normalize_title($tit);
    ( $flag{stit}, $norm{stit}, $flag{tvol}, $norm{tvol1}, $norm{tvol2} )         = check_subtitles( $stit, $v1, $v2 );
    ( $norm{add}, $flag{avol}, $norm{avol_no}, $norm{avol_tit} )                  = check_addendum($add);
    ( $flag{ana}, $norm{src}, $norm{srctit}, $norm{srcaut} )                      = check_analytica($add);
    ( $flag{year}, $norm{year}, $norm{year_p1}, $norm{year_m1} )                  = normalize_year($year);
    ( $flag{range}, $flag{pub}, $flag{place}, $norm{place}, $norm{pub} )          = check_ppp( $pag, $pub, $place );   
    ( $norm{doctype}, $flag{ana}, $flag{isbn1}, $flag{isbn2}, $flag{year}, $mat ) = set_material_codes(\%flag, $mat, $year);

    # debug:
    print_hash(\%flag, $fh_report);
    print_hash(\%norm, $fh_report);

	# -----
	# check if record should be ignored => if yes, skip this record:
	# -----

    if ( ( $code1 =~ /^Z/ ) || ( $mat =~ /CD-ROM|online/ ) || ( $norm{tit} =~ m/$blacklist/i ) )    {
        @export = prepare_export($line, \@export, "ignore");
        $ctr{ignore}++;
        $ctr{journal}++;
        next;
    } else {
    	$norm{carrier} = 'nc'; # carrier type code for printed volume (= remaining documents)
    }

	# ----
	# prepare search terms by escaping them
	# ----
	
    my %esc;     
    ($esc{isbn}, $esc{year}, $esc{tit}, $esc{aut}, $esc{pub}, $esc{place}) = clean_search_params(\%norm, \%flag);
    
    # -----
    # start search: build sru query, get xpath and result set
    # -----
    
    my @records;    # array for records in result set
    my $xpc  		= build_sruquery_basic($base_url, $config, \%flag, \%esc);
    my $rec_nrs   	= get_record_nrs($xpc, $config);

    if ( $rec_nrs == 0 ) {
    	# broader query:
    	$xpc        = build_sruquery_broad($base_url, $config, \%flag, \%esc);
        $rec_nrs    = get_record_nrs($xpc, $config);

        if ( $rec_nrs == 0 || $rec_nrs >= $window ) {
            @export = prepare_export($line, \@export, "notfound");
            $ctr{notfound}++;
            $ctr{nohits}++;
            next;
        } else {
            @records = get_xpc_nodes($xpc, $config);
        }
    } elsif ( $rec_nrs >= $window ) {
        # narrower query:
        $xpc         = build_sruquery_narrow($base_url, $config, \%flag, \%esc);
        $rec_nrs     = get_record_nrs($xpc, $config);
        if ( $rec_nrs == 0 || $rec_nrs >= $window ) {
            @export  = prepare_export($line, \@export, "notfound");
            $ctr{notfound}++;
            $ctr{nohits}++;
            next;
        } else {
            @records = get_xpc_nodes($xpc, $config);
        } 
    } else {
        @records = get_xpc_nodes($xpc, $config);
    }

    # -------------
    # start comparing the results: loop through result set
    # -------------

    my $i = 0;
    my @replace = ();     
    foreach my $rec (@records) {
        $i++;
        print_doc_header( $fh_report, $i, $opts{c} );
        my $sysno = get_controlfield( '001', $config, $rec, $xpc );

        # ----
        # compare selected values in result set and get match values
        # ----
        
        my ($subtotal, $unsafe) = evaluate_records(\%flag, \%norm, $config, $rec, $xpc);   
        if ($unsafe) {
        	next;
        }
                
        # ----
        # check for best network (origin): 
		# ----
		
    	my $m035_counter = 0;
    	my $nw_match     = 0;
    	my ($r_ref, $case);
	    if ($GVI) {
	    	( $m035_counter, $nw_match, $r_ref, $case ) = check_network_g ( $config, $rec, $xpc );
	    } else {
	    	( $m035_counter, $nw_match, $r_ref, $case ) = check_network_s ( $config, $rec, $xpc, $rec_nrs, \%flag, $subtotal, \@replace, $sysno, $callno);
	    }
		if (defined $case) {
    		$flag{case} = $case;
    		print $fh_report Dumper $case;
    	}

    	my $total = $subtotal + $m035_counter + $nw_match; 
		# debug:
    	print $fh_report Dumper $total;

		if (defined $r_ref) {
    		@replace = @{$r_ref};
    		if (defined $replace[0]) {
    			print $fh_report "Replace: ".$replace[0]."\n";
    		}    		
    	}

        # ----
        # safe record if best match 
		# ----
		
        if ( $total > $bestmatch[0]){ 
            @bestmatch = (); 
            push @bestmatch, $total, $sysno, $rec;
            print $fh_report "NEW BEST MATCH: $total\n";
        }

    } 
    # end of foreach loop (going through each record in results list)
	
    print $fh_report "Bestmatch: $bestmatch[0], Bestrecordnr: $bestmatch[1] \n";
    
    # ----------------
    # handle best result:
    # ----------------
    
    my $xml;
    if ($bestmatch[0] >= $m_safe) {
    	if ($GVI) {
    		# for GVI results:
    		$ctr{found}++;
    		@export = prepare_export($line, \@export, "found", $bestmatch[1]);
    		$xml = create_MARCXML($bestmatch[2], \%subj_hash, $code1, $code2, $code3);
    		print $fh_XML $xml;   
    	} else {
    		# for swissbib results:
			if (defined $flag{case} && $flag{case} eq 'iffonly') {
				# only the original import was found:
	    		@export = prepare_export($line, \@export, "iffonly", undef, $replace[0]);
	    		$ctr{ignore}++;
	    		$ctr{iffonly}++;
	    		next; 
	    	}
    		if (defined $replace[0]) {
    			if ( $replace[0] eq $bestmatch[1] ) {
    				if (defined $flag{case} && $flag{case} eq 'bestcase') {
    					# best case scenario: old and new IDSSG already matched.
    					$ctr{best}++;
    					$ctr{found}++;
	    				@export = prepare_export($line, \@export, "bestcase");  
    				} else {
    					# document needs to be reimported
    					$ctr{reimport}++;
    					$ctr{found}++;
    					@export = prepare_export($line, \@export, "reimport", $bestmatch[1], $replace[0]);
						$xml = create_MARCXML($bestmatch[2], \%subj_hash, $code1, $code2, $code3);
    					print $fh_XML $xml;
    				}
	    		} else {
	    			# document needs to be replaced:
	    			$ctr{replace}++;
	    			@export = prepare_export($line, \@export, "replace", $bestmatch[1], $replace[0]);
					$xml = create_MARCXML($bestmatch[2], \%subj_hash, $code1, $code2, $code3);
    				print $fh_XML $xml;
    				$ctr{found}++;
	    		}
	    	} else {
	    		# the original iff record was not found:
	    		@export = prepare_export($line, \@export, "iffnotfound", $bestmatch[1]);
	    		$ctr{iffnotfound}++;
	    		$ctr{notfound}++;	    		
	    	}    		
    	}
    } else {
    	# unsafe match
        @export = prepare_export($line, \@export, "unsafe");
        $ctr{unsafe}++; 
        $ctr{ignore}++;     
    }
    
} 
# end of while loop (going through every input line)

# --------------------------
# Create output, count time, create statistics
# --------------------------

# print out files
print $fh_XML '</data>';

$csv->eof or $csv->error_diag();
$csv->say( $fh_out, $_ ) for @export;

# close files
close $fh_in;
close $fh_report or die "report.txt: $!";
close $fh_out    or die "export.csv: $!";
close $fh_XML    or die "metadata.xml: $!";

# measure time:
my $endtime     = time();
my $timeelapsed = $endtime - $starttime;

printStatistics(\%ctr, $timeelapsed);

######################################################################################
# End of main script
######################################################################################

=head1 SUBROUTINES

=head2 NORMALISATION ROUTINES

=over 4

=item normalize_isbn()

This function normalizes isbn numbers, checks if one or two isbn are present, 
sets flags and returns the normalized isbn and flags.

Arguments: 
$originalIsbn: string with original isbn

Returns: 
$n_isbn1, $n_isbn2: strings, 
$flag_isbn1, $flag_isbn2: numbers (1 or 0) 

=back

=cut

sub normalize_isbn {
    my $originalIsbn = shift;
    my ( $n_isbn1, $n_isbn2, $flag_isbn1, $flag_isbn2 );

    # 	remove all but numbers and X
    $originalIsbn =~ s/[^0-9xX]//g;
    my $isbnlength = length($originalIsbn);

    # check for valid numbers and set flags accordingly
    if ( $isbnlength == 26 ) {

        #there are two ISBN-13
        $n_isbn2 = substr $originalIsbn, 13;
        $n_isbn1 = substr $originalIsbn, 0, 13;
        $flag_isbn1 = 1;
        $flag_isbn2 = 1;
    }
    elsif ( $isbnlength == 20 ) {

        #there are two ISBN-10
        $n_isbn2 = substr $originalIsbn, 10;
        $n_isbn1 = substr $originalIsbn, 0, 10;
        $flag_isbn1 = 1;
        $flag_isbn2 = 1;
    }
    elsif ( $isbnlength == 13 || $isbnlength == 10 ) {

        #one valid ISBN
        $n_isbn1    = $originalIsbn;
        $n_isbn2    = undef;
        $flag_isbn1 = 1;
        $flag_isbn2 = 0;
    }
    else {
        # not a valid isbn number
        $flag_isbn1 = 0;
        $flag_isbn2 = 0;
        $n_isbn1    = undef;
        $n_isbn2    = undef;
    }

    return ( $n_isbn1, $n_isbn2, $flag_isbn1, $flag_isbn2 );
}

=over 4

=item normalize_author()

This function normalizes authors, checks for authorities, sets flags and returns the normalized authors and flags.

Arguments: 
$originalAuthor: original author string

Returns: 
$normalizedauthor: string, 
$flag: number (0 or 1)

=back

=cut

sub normalize_author {
    my $originalAuthor = shift;
    my $authorflag;
    my $authorsize;
    my @authority;

    my $authorityWords = $config->{regex}->{authority};
    my $lastname;

    if ( $originalAuthor =~ /\A\Z/ ) {

        # author row is empty
        $authorflag = 0;
        $lastname   = undef;
    }
    else {
        $authorflag = 1;

        # check for authority
        if ( $originalAuthor =~ /$authorityWords/i ) {
            $authorsize = 5;    # is an authority
        }
        else {
            @authority  = split( ' ', $originalAuthor );
            $authorsize = scalar @authority;
        }
        if ( $authorsize <= 3 ) {

            # probably a person, trim author's last name:
            if ( $originalAuthor =~ /\Avon\s|\Ade\s|\Ale\s/i ) {
                $lastname = ( split /\s/, $originalAuthor, 3 )[1];
            }
            else {
                $lastname = ( split /\s/, $originalAuthor, 2 )[0];
            }
        }
        else {
            # keep the full name (is an authority)
            $lastname = $originalAuthor;
        }
    }
    $lastname = trim($lastname);    # remove whitespaces
    return ( $lastname, $authorflag );
}


=over 4

=item check_addendum()

This function checks addendum for volume information, sets flags and returns the volume information and flags.

Arguments: 
$origAddendum: original addendum string

Returns: 
$origAddendum, $vol_number, $vol_title: strings, 
$volume_flag: number (0 or 1)

=back

=cut

sub check_addendum {
    my $origAddendum = shift;
    my ( $volume_flag, $vol_title, $vol_number );

    if ( $origAddendum =~ /\A\Z/ ) {
        $origAddendum = undef;
    }
    elsif (
        $origAddendum =~ /^(Band|Bd|Vol\.|Volume|Reg|Gen|Teil|d{1}\sTeil|I{1,3}\sTeil).*:/ )
    {
        # volume title information at beginning of addendum
        $volume_flag = 1;
        $vol_title  = ( split /: /, $origAddendum, 2 )[1];
        $vol_number = ( split /: /, $origAddendum, 2 )[0];
    }
    elsif ( $origAddendum =~ /\- (Bd|Band|Vol\.|Volume)/ ) {

        # volume title information in the middle/end of addendum
        $volume_flag = 1;
        $vol_number = ( split /- /, $origAddendum, 2 )[1];
        $vol_title  = ( split /- /, $origAddendum, 2 )[0];
    }
    else {
        $volume_flag = 0;
        $vol_number  = undef;
        $vol_title   = undef;
    }

    return ($origAddendum, $volume_flag, $vol_number, $vol_title );
}


=over 4

=item check_analytica() 

This function checks if there is source information for an analyticum in the addendum.

Arguments: 
$originaladdendum: original addendum string

Returns: 
$citation, $src_title, $src_author: strings, 
$analytica_flag: number (0 or 1)

=back

=cut


sub check_analytica {

    my $originaladdendum = shift;
    my ( $analytica_flag, $citation, $src_title, $src_author );

    if ( defined $originaladdendum && $originaladdendum =~ m/in: /i ) {
        $analytica_flag = 1;
        $citation       = $originaladdendum;
        $citation =~ s/^in: //i;    #replace "in: "
        $src_title  = ( split /: /, $citation, 2 )[1];
        $src_author = ( split /: /, $citation, 2 )[0];
    } else {
        $analytica_flag   = 0;
        $originaladdendum = $citation = $src_title = $src_author = undef;
    }
    return ( $analytica_flag, $citation, $src_title, $src_author );
}


=over 4

=item normalize_title()

This function normalizes the title and returns it.

Arguments: 
$originalTitle: original title string

Returns: 
$originalTitle: string

=back

=cut

sub normalize_title {

    my $originalTitle = shift;

    $originalTitle =~ s/^L\'//g;    #remove L' in the beginning
    $originalTitle =~
      s/eidg\./eidgen\xf6ssischen/i;    #replace with correct umlaut
    $originalTitle =~ s/st\.gall/st gall/i;
    $originalTitle = trim($originalTitle);    # remove whitespaces
    return $originalTitle;
}

=over 4

=item check_subtitles()

This function checks rows subtitle, volume1 and volume2 for sensible information, 
sets flag accordingly and normalizes the strings.

Arguments: 
$originalSubtitle, $originalTitVol1, $originalTitVol2: original subtitle strings

Returns: 
$stit_flag, $volume_flag: numbers (0 or 1), 
$n_stit, $volumeTitle1, $volumeTitle2: strings

=back

=cut


sub check_subtitles {
    my $originalSubtitle = shift;
    my $originalTitVol1  = shift;
    my $originalTitVol2  = shift;
    my ( $stit_flag, $n_stit, $volume_flag, $volumeTitle1, $volumeTitle2 );
    if ( $originalSubtitle =~ /\A\Z/ ) {
        $stit_flag = 0;
        $n_stit    = undef;
    }
    else {
        $stit_flag = 1;
        $n_stit    = normalize_title($originalSubtitle);
    }
    if ( $originalTitVol1 =~ /\A\Z/ ) {
        $volume_flag  = 0;
        $volumeTitle1 = undef;
        $volumeTitle2 = undef;
    }
    else {
        $volume_flag  = 1;
        $volumeTitle1 = normalize_title($originalTitVol1);
        if ( $originalTitVol2 =~ /\A\Z/ ) {
            $volumeTitle2 = undef;
        }
        else {
            $volumeTitle2 = normalize_title($originalTitVol2);
        }
    }
    return ( $stit_flag, $n_stit, $volume_flag, $volumeTitle1, $volumeTitle2 );
}

=over 4

=item normalize_year()

This function ensures that the year variable contains four digits and selects the latest year.
It calculates the year-range for the sru query (one year above and below original value).

Arguments: 
$originalYear: string

Returns: 
$year_flag: number (0 or 1), 
$originalYear, $ym1, $yp1: numbers (d{4})

=back

=cut


sub normalize_year {
    my $originalYear = shift;
    my ( $year_flag, $yp1, $ym1 );
    if ( $originalYear !~ /\A\Z/ && $originalYear =~ /\d{4}/ ) {

        # year contains 4 digits
        $year_flag    = 1;
        $originalYear = substr $originalYear,
          -4;    # in case of several years, take the last one
        $ym1 = ( $originalYear - 1 );
        $yp1 = ( $originalYear + 1 );
    }
    else {       # no usable year, eg. "online" or "aktuell"
        $year_flag    = 0;
        $originalYear = undef;
        $ym1          = undef;
        $yp1          = undef;
    }
    return ( $year_flag, $originalYear, $ym1, $yp1 );
}

=over 4

=item check_ppp() 

This function checks if pages, publisher and place contain information.
It also checks if pages contain a range and are therefore analytica.

Arguments: 
$originalPages, $originalPublisher, $originalPlace: strings

Returns: 
$pagerange_flag, $pub_flag, $place_flag: number (0 or 1), 
$originalPlace, $originalPublisher: strings

=back

=cut

sub check_ppp {

    my $originalPages     = shift;
    my $originalPublisher = shift;
    my $originalPlace     = shift;
    my ( $pagerange_flag, $pub_flag, $place_flag );
    if ( $originalPages !~ /\A\Z/ && $originalPages =~ /\-/ ) {

        #very likely not a monograph but a volume or article
        $pagerange_flag = 1;
    }
    else { $pagerange_flag = 0; }

    if ( $originalPublisher =~ /\A\Z/ ) {
        $pub_flag = 0;
    }
    else { $pub_flag = 1; }

    if ( $originalPlace =~ /\A\Z/ ) {
        $place_flag = 0;
    }
    else { $place_flag = 1; }

    return ( $pagerange_flag, $pub_flag, $place_flag, $originalPlace, $originalPublisher );
}


=over 4

=item set_material_codes() 

This function deals with diverse material codes and returns correct type and changes some flags.
It also disables some search values depending on material code.

Arguments: 
$flag_ref: hash reference to %flag, 
$material: string, 
$year: number

Returns: 
$type: character (m, a or i), 
$flag{ana}, $flag{isbn1}, $flag{isbn2}, $flag{year}: number (0 or 1), 
$material: string

=back

=cut

sub set_material_codes {
	my $flag_ref = shift;
	my $material = shift;
	my $year = shift;
	my $type = 'm'; # default LDR value: monographs
	my %flag = %{$flag_ref};
	
	# following documents should be treated like analytica and therefore isbn-search disabled:
	if ($flag{range} ==1 || $flag{ana} ==1) {
		$flag{ana} = 1;
		$flag{isbn1} = 0;
		$flag{isbn2} = 0;
		$type = 'a';
	}
	if ($material =~ /Loseblatt/ ) {
        $flag{year} = 0;               # year for Loseblatt is usually wrong
        $type  = qr/m|i/;              # doctype can be both.
    }
	if ( $year =~ /online/i ) {
        $material = "online";
    }
    return ($type, $flag{ana}, $flag{isbn1}, $flag{isbn2}, $flag{year}, $material);
	
}
                  

=over 4

=item clean_search_params() 

This function tidies the normalized title/author strings and escapes them for the sru query building.

Arguments: 
$flag_ref, $norm_ref: hash references (%flag, %norm)

Returns: 
$escaped_isbn, $escaped_year, $escaped_title, $escaped_author, $escaped_publisher, $escaped_place: strings

=back

=cut


sub clean_search_params {
	
	my $norm_ref = shift;
	my $flag_ref = shift;
	my %norm = %{$norm_ref};
	my %flag = %{$flag_ref};
	# clean characters: .()'"/+[]? and remove and / or / within
	my $CLEAN_TROUBLE_CHAR = qr/\.|\(|\)|\'|\"|\/|\+|\[|\]|\?/; 
	my $stopwords = qr/ and | or | within /;   
	my ($escaped_isbn, $escaped_year, $escaped_title, $escaped_author, $escaped_publisher, $escaped_place);
	
	if ($flag{isbn1}) {
		$escaped_isbn = $norm{isbn1};
	} else {
		$escaped_isbn = '';
	}
	if ($flag{year}) {
		$escaped_year = $norm{year};
	} else {
		$escaped_year = '';
	}
	
	$escaped_title = $norm{tit};
	$escaped_title =~ s/$CLEAN_TROUBLE_CHAR//g;
	$escaped_title =~ s/$stopwords/ /g;
    $escaped_title = uri_escape_utf8($escaped_title);
    
	if ($flag{aut1}) {
	    $escaped_author = $norm{aut1};
		$escaped_author =~ s/$CLEAN_TROUBLE_CHAR//g;
		$escaped_author =~ s/$stopwords/ /g;
    	$escaped_author = uri_escape_utf8($escaped_author); 
	} else {
		$escaped_author = '';
	}
	
	if ($flag{pub}) {
	    $escaped_publisher = $norm{pub};
		$escaped_publisher =~ s/$CLEAN_TROUBLE_CHAR//g;
		$escaped_publisher =~ s/$stopwords/ /g;
	    $escaped_publisher = uri_escape_utf8($escaped_publisher); 		
	} else {
		$escaped_publisher = '';
	}
	
	if ($flag{place}) {
		$escaped_place = $norm{place};
		$escaped_place =~ s/$CLEAN_TROUBLE_CHAR//g;
		$escaped_place =~ s/$stopwords/ /g;
    	$escaped_place = uri_escape_utf8($escaped_place); 
	} else {
		$escaped_place = '';
	}
    
    return ($escaped_isbn, $escaped_year, $escaped_title, $escaped_author, $escaped_publisher, $escaped_place );

}


=head2 MATCH ROUTINES

=over 4

=item get_controlfield() 

This function checks if a specific MARC controlfield exists and returns its content.

Arguments: 
$controlfield_nr: number (MARC controlfield), 
$conf: configuration object, 
$record: object (current record node) , 
$xpath: object (current xpath context), 

Returns: 
$controlfield_content: string or undef

=back

=cut

sub get_controlfield {
    my $controlfield_nr = shift;
    my $conf            = shift;
    my $record          = shift;
    my $xpath           = shift;
    my $controlfield_content;
    my $ctrlfield = $conf->{sru}->{ctrlfield};

    if ($xpath->exists($ctrlfield .'[@tag='. $controlfield_nr . ']', $record ))  {
        foreach my $el ( $xpath->findnodes($ctrlfield .'[@tag='. $controlfield_nr . ']', $record )) {
            $controlfield_content = $el->to_literal;
            print $fh_report "$controlfield_nr: $controlfield_content";
        }
    } else {
        $controlfield_content = undef;
    }
    return $controlfield_content;
}

=over 4

=item hasTag() 

This function checks if a MARC field (datafield) exists.

Arguments: 
$tag: number (MARC datafield), 
$conf: configuration object, 
$record: object (current record node) , 
$xpath: object (current xpath context), 

Returns: 
1 or 0 (true or false)

=back

=cut


sub hasTag {
    my $tag          = shift;    
    my $conf         = shift;    
    my $record       = shift;    
    my $xpath        = shift;    
    my $datafield    = $conf->{sru}->{datafield};

    if ($xpath->exists( $datafield.'[@tag='. $tag . ']', $record ) ) {
        return 1;
    } else {
        return 0;
    }

}


=over 4

=item checkIsbnMatch() 

This function checks if ISBN numbers match.

Arguments:
$record: object (current record node),  
$xpath: object (current xpath context), 
$original_isbn: number (isbn number from original data), 
$conf: configuration object

Returns: 
$matchvalue: number

=back

=cut

sub checkIsbnMatch {
    my $record        = shift;
    my $xpath         = shift;
    my $original_isbn = shift;
    my $conf          = shift;
    my $isbn_match    = $conf->{match}->{isbn};
    my $datafield     = $conf->{sru}->{datafield};
    my $subfield      = $conf->{sru}->{subfield};
    my $matchvalue    = 0;

    foreach my $el ( $xpath->findnodes( $datafield .'[@tag=020]', $record ) ) {
        my $marc_20_a = $xpath->findnodes($subfield.'[@code="a"]', $el )->to_literal;
        $marc_20_a =~ s/[^0-9xX]//g;
        print $fh_report "020 a $marc_20_a\n";

        if ( $original_isbn =~ m/$marc_20_a/i ) {
            $matchvalue += $isbn_match;
        }
    }
    return $matchvalue;
}

=over 4

=item getMatchValue() 

This function compares the content of a MARC field to an original string and returns a match value.

Arguments:
$df_content: number (MARC datafield), 
$sf_content: number (MARC subfield), 
$hash_ref: hash reference (%norm), 
$key: string (hash key), 
$conf: configuration object, 
$record: object (current record node), 
$xpath: object (current xpath context), 

Returns: 
$matchvalue: number

=back

=cut

sub getMatchValue {
    my $df_content     = shift;
    my $sf_content     = shift;
    my $hash_ref       = shift;
    my $key            = shift;
    my $conf           = shift;
    my $record         = shift;
    my $xpath          = shift;
    my %norm 		   = %{$hash_ref};
    my $originalstring = $norm{$key};
   	my $matchvalue     = $conf->{match}->{$key};
	my $datafield      = $conf->{sru}->{datafield};
    my $subfield       = $conf->{sru}->{subfield};
    my $CLEAN_TROUBLE_CHAR = qr/\.|\(|\)|\'|\"|\/|\+|\[|\]|\?|\,|/; #clean following characters: .()'"/+[]?,
    
    if (defined $originalstring ) {
    	# continue with comparison
    	foreach my $el ( $xpath->findnodes($datafield.'[@tag="' . $df_content . '"]', $record  ) ) {
   			my $marcfield = $xpath->findnodes( $subfield.'[@code="' . $sf_content . '"]', $el )->to_literal;
        	$marcfield =~ s/$CLEAN_TROUBLE_CHAR//g;    # clean fields from special characters
	        if ( $marcfield =~ /\A\Z/ ) {
	            # subfield is empty and therefore does not exist:
	            return 0;
	        } else {
	        	print $fh_report "$df_content $sf_content $marcfield\n";
	        	$originalstring =~ s/$CLEAN_TROUBLE_CHAR//g;    # clean fields from special characters  
	        	if (( $originalstring =~ m/$marcfield/i ) || ( $marcfield =~ m/$originalstring/i ) ) {
		            #Marc data matches original data
		            return $matchvalue;	        	
		        } else {
		        	#Marc data does not match original data
		        	return 0;
		        }
	        }
    	}    	
    } else {
    	# original string is not initialized, abort
    	return 0;
    }
}

=over 4

=item checkMaterial() 

This function checks the LDR field in the MARC record, cuts aut position 07 and compares it to the doctype.

Arguments:
$hash_ref: hash reference (%norm), 
$type: character, 
$conf: configuration object, 
$record: object (current record node),  
$xpath: object (current xpath context) 

Returns: 
$matchvalue: number

=back

=cut

sub checkMaterial {
	my $hash_ref = shift;
    my $type     = shift;
    my $conf     = shift;
    my $record   = shift;
    my $xpath    = shift;
    my $ldr;
    my $matchvalue;
    my %norm     = %{$hash_ref};
	my $posmatch = $conf->{match}->{material};
	my $leader   = $conf->{sru}->{leader};

    if ( $xpath->exists( $leader, $record ) ) {
        foreach my $el ( $xpath->findnodes( $leader, $record ) ) {
            $ldr = $el->to_literal;
            $ldr = substr $ldr, 7, 1;    #LDR pos07
            print $fh_report Dumper $ldr;
            if ( $norm{$type} =~ m/$ldr/ ) {
                $matchvalue = $posmatch;
            }
            else {
                $matchvalue = 0;
            }
        }
    }
    return $matchvalue;
}

=over 4

=item check_network_g() 

This function checks origins of each record in the GVI (= which network is the currently evaluated record coming from?). 
It gets the MARC field 035 from the record and decides on a network match value based on the configuration.
It also counts the number of MARC fields 035, based on the assumption that 
the more networks contributed to this record, the better the quality will be.

Arguments:
$conf: configuration object, 
$record: object (current record node),  
$xpath: object (current xpath context) 

Returns: 
$m035_counter, $highestvalue: number

The function also returns two undef values to be compliant with check_network_s() (see below).

=back

=cut

sub check_network_g {
    my $conf   = shift;
    my $record = shift;
    my $xpath  = shift;

    # GVI best networks:
    my $bsz             = $conf->{net}->{BSZ};
    my $bvb             = $conf->{net}->{BVB};
    my $gbv             = $conf->{net}->{GBV};
    my $kobv            = $conf->{net}->{KOBV};
    my $hbz             = $conf->{net}->{HBZ};
    my $heb             = $conf->{net}->{HEBIS};
    my $dnb             = $conf->{net}->{DNB};
    my $obv             = $conf->{net}->{OBV};
	my $datafield       = $conf->{sru}->{datafield};
    my $subfield        = $conf->{sru}->{subfield};
    my $MARC035a;
    my $matchvalue      = 0;
    my $highestvalue    = 0;
    my $m035_counter    = 0;
    
    if (hasTag( "035", $conf, $record, $xpath )) {
    	foreach my $el ( $xpath->findnodes( $datafield.'[@tag=035 ]', $record ) ) {
    		$MARC035a = $xpath->findnodes( $subfield.'[@code="a"]', $el )->to_literal;
    		if ($MARC035a !~ /OCoLC/) { 
    			# ignore 035 fields starting with (OCoLC) 
    			print $fh_report "035 a " . $MARC035a . "\n";
    			$m035_counter++;
    			if (   $MARC035a =~ /BSZ|DE-627|DE-576|DE-615/ ) {
	                $matchvalue = $bsz;
	            } elsif ( $MARC035a =~ /BVB|DE-604/ ) {
                	$matchvalue = $bvb;
            	} elsif ($MARC035a =~ /GBV/) {
            		$matchvalue = $gbv;
            	} elsif ($MARC035a =~ /HBZ|DE-605/) {
            		$matchvalue = $hbz;
            	} elsif ($MARC035a =~ /HEB|DE-603/) {
            		$matchvalue = $heb;
            	} elsif ($MARC035a =~ /DNB|DE-101|ZDB/) {
            		$matchvalue = $dnb;
            	} elsif ($MARC035a =~/KBV/) {
            		$matchvalue = $kobv;
            	} elsif ($MARC035a =~ /OBV/) {
            		$matchvalue = $obv;
            	} else {
            		# all other networks
            		$matchvalue = 0;
            	}
            	if ($matchvalue >= $highestvalue) {
            		$highestvalue = $matchvalue;
            	}            	    			
    		}
    	}
    } 
    # last 2 values: $r_ref, $case analog to swissbib routine
    print $fh_report Dumper ($m035_counter, $highestvalue);
    return ( $m035_counter, $highestvalue, undef, undef);
}

=over 4

=item check_network_s() 

This function checks origins of each record in Swissbib (= which network is the currently evaluated record coming from?). 
It gets the MARC field 035 from the record and decides on a network match value based on the configuration.
It also counts the number of MARC fields 035, based on the assumption that 
the more networks contributed to this record, the better the quality will be.
Additionaly, this routine checks if the current record is an IDSSG record. 
If yes, the age of the record is evaluated. If this record is in a certain number range, it is from the
original IFF upload from May 2018 and therefore needs to be replaced, if a better match is found.
If this is the only result, it is marked with "iffonly" and returned immediately. 
Otherwise the IFF number is stored in an array and returned. 
If it is an older IDSSG document, the function checks whether the IFF document was already attached. 
If this is the case, it is marked with "bestcase".
A lot of points get alloted for old IDSSG documents so that they should always be the winner to reduce local duplicates.

Arguments:
$conf: configuration object, 
$record: object (current record node), 
$xpath: object (current xpath context), 
$rec_nrs, $subtotal, : number, 
$flag_ref, $replace_ref: hash references, 
$sysno, $callno: strings

Returns: 
$m035_counter, $highestvalue: number, 
\@iff2replace: array reference, 
$case: string

=back

=cut

sub check_network_s {
    my $conf   = shift;
    my $record = shift;
    my $xpath  = shift;
    my $rec_nrs = shift;
    my $flag_ref = shift;
    my $subtotal = shift;
    my $replace_ref = shift;
    my $sysno = shift;
    my $callno = shift;
    my %flag = %{$flag_ref};
    my @iff2replace = @{$replace_ref};
    my $MARC035a;
    my $case = undef;

    # Swissbib best networks:
    my $ids             = $conf->{net}->{IDS};
    my $sgbn            = $conf->{net}->{SGBN};
    my $rero            = $conf->{net}->{RERO};
   	# ranking for iff records
    my $idssg_old_m     = $conf->{net}->{IDSSG_OLD_M};
    my $idssg_old_a     = $conf->{net}->{IDSSG_OLD_A};
    my $iff_m           = $conf->{net}->{IFF_M};
    my $iff_a           = $conf->{net}->{IFF_A};
    
	my $datafield       = $conf->{sru}->{datafield};
    my $subfield        = $conf->{sru}->{subfield};
    my $slspmatch       = 0;
    my $idssgmatch      = 0;
    my $highestvalue    = 0;
    my $m035_counter    = 0;
    my $hsb01_nr        = '';
   	my $iff_deduct      = 0;  


   	my $MARC949F; 
   	my $MARC949j;
    
    if (hasTag( "035", $conf, $record, $xpath )) {
    	# first, count the number of 035 fields:
    	foreach my $el ( $xpath->findnodes( $datafield.'[@tag=035 ]', $record ) ) {
    		$MARC035a = $xpath->findnodes( $subfield.'[@code="a"]', $el )->to_literal;		
    		if ($MARC035a !~ /OCoLC/) {
    			# only count if not an OCoLC number
    			print $fh_report "035 a " . $MARC035a . "\n";
    			$m035_counter++ ;
    		}
    	}
    	# then, find best network:    	
    	foreach my $el ( $xpath->findnodes( $datafield.'[@tag=035 ]', $record ) ) {
    		$MARC035a = $xpath->findnodes( $subfield.'[@code="a"]', $el )->to_literal;
    		if ( $MARC035a !~ /IDSSG/ ) {
    			if ( $MARC035a =~ /RERO/ ) {
    				$slspmatch = $rero;
    			} elsif ($MARC035a =~ /SGBN/ ){
    				$slspmatch = $sgbn;
    			} elsif ($MARC035a =~ /IDS|NEBIS/) {
    				$slspmatch = $ids;
    			} else {
    				#other network:
    				$slspmatch = 0;
    			}
    			if ($slspmatch >= $highestvalue) {
            		$highestvalue = $slspmatch;
            	}

    		} else {
    			# IDSSG-RECORDS: check age (number range):    			
				$hsb01_nr = substr $MARC035a,-7;  
				if ( $hsb01_nr >= 991054 ) {
					# IFF original upload, May 2018:
					if (($rec_nrs) == 1 && ($m035_counter <= 1)) {
						# this is the only result: no need for further evaluation, record cannot be improved.
						push @iff2replace, $sysno, $hsb01_nr, $subtotal;
						return ( $m035_counter, $highestvalue, \@iff2replace, "iffonly");
					} elsif ($rec_nrs == 1 ) { 
						# there is only 1 result but several 035-fields: reimport case
						$iff_deduct = 0;
					} else {
						# set deduction points for iff record
						if ($flag{ana}) {
							$iff_deduct = $iff_a;
						} else {
							$iff_deduct = $iff_m;
						}
						print $fh_report Dumper ($iff_deduct);
					}		
					if (defined $iff2replace[0] && ($iff2replace[2]>$subtotal)) {
						#do nothing, a better iff doc was already found
					} else {
						push @iff2replace, $sysno, $hsb01_nr, $subtotal; 
					}			
				} else {
					# old record from IDSSG: make sure that this is the winner!
					if ($flag{ana} || $flag{tvol} || $flag{avol}) {
						$idssgmatch = $idssg_old_a;
					} else {
						$idssgmatch = $idssg_old_m;
					}
					# check for bestcase: IFF and HSG already matched?
					if (hasTag("949", $conf,$record, $xpath )) {
						foreach my $el ( $xpath->findnodes( $datafield.'[@tag=949 ]', $record ) ) {
							$MARC949F =  $xpath->findnodes( $subfield.'[@code="F"]', $el )->to_literal;
							if ($xpath->exists($subfield.'[@code="j"]', $el)) {
								$MARC949j =  $xpath->findnodes( $subfield.'[@code="j"]', $el )->to_literal;
							}
							# check if this is the same IFF record as $callno
							if ( $MARC949F =~ /HIFF/ && $MARC949j =~/$callno/) {
							  	print $fh_report "949: $MARC949F $MARC949j --- Original callno: $callno \n";
							  	$idssgmatch += 10;
							  	# debug: print $fh_report "Best case: IFF attached, IDSSGMATCH = $idssgmatch \n";
							  	push @iff2replace, $sysno, $hsb01_nr, $subtotal;
							  	$case = "bestcase";
							}
						}	
					}									
				}
				# debug: print $fh_report Dumper ($idssgmatch, $case);
				if ($idssgmatch >= $highestvalue) {
					$highestvalue = $idssgmatch;
				}
				$highestvalue -= $iff_deduct;
    		}
    	}
    } 
    print $fh_report Dumper ($m035_counter, $highestvalue);
    return ( $m035_counter, $highestvalue, \@iff2replace, $case);
}

=over 4

=item evaluate_records() 

This function deals with all the matching for each record in the result set. 
It compares the different input values with the according MARC fields/subfields:
ISBN, Author/Authority, Title, Subtitle, Year, Place, etc.
The function also eliminates totally unsafe matches.

Arguments:
$flag_ref, $norm_ref: hash references, 
$config: configuration object, 
$rec: object (current record node), 
$xpc: object (current xpath context) 

Returns: 
$total: number, 
$unsafe: number (1 or 0);

=back

=cut

sub evaluate_records {
	
	my $flag_ref = shift;
	my $norm_ref = shift;
	my $config = shift;
	my $rec = shift;
	my $xpc = shift;
    my %norm = %{$norm_ref};
    my %flag = %{$flag_ref};
    my $total = 0;
    my $unsafe = 0;
    
    # compare ISBN:
    my $i_match = 0;
    if ( $flag{isbn1}  && ( hasTag( "020", $config, $rec, $xpc ) ) ) {
    	$i_match = checkIsbnMatch( $rec, $xpc, $norm{isbn1}, $config);
    }
    if ( $flag{isbn2}  && ( hasTag( "020", $config, $rec, $xpc ) ) ) {
        $i_match += checkIsbnMatch( $rec, $xpc, $norm{isbn2}, $config);
    }
    print $fh_report Dumper $i_match;
    $total += $i_match;
    
    # compare Author/Authority/other associated persons
   	my $a1_match = 0;
	my $a2_match = 0;
	if ($flag{aut1}) {
		if ( hasTag( "100", $config, $rec, $xpc ) ) {
			$a1_match = getMatchValue( "100", "a", \%norm, "aut1", $config, $rec, $xpc );
        } elsif ( hasTag( "700", $config, $rec, $xpc ) ) {
			$a1_match = getMatchValue( "700", "a", \%norm, "aut1", $config, $rec, $xpc );
		} elsif ( hasTag( "110", $config, $rec, $xpc ) ) {
            $a1_match = getMatchValue( "110", "a", \%norm, "aut1", $config, $rec, $xpc );
        } elsif ( hasTag( "710", $config, $rec, $xpc ) ) {
            $a1_match = getMatchValue( "710", "a", \%norm, "aut1", $config, $rec, $xpc );
        }
    }
    if ($flag{aut2}) {
    	if ( hasTag( "100", $config, $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "100", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "700", $config, $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "700", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "110", $config, $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "110", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "710", $config, $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "710", "a", \%norm, "aut2", $config, $rec, $xpc );
    	}
    }
    print $fh_report Dumper $a1_match;
    print $fh_report Dumper $a2_match;
    $total += ($a1_match + $a2_match);
    
	# compare title & subtitle fields
	my $t_match  = 0;
	my $st_match = 0;
	if ( hasTag( "245", $config, $rec, $xpc ) ) {
		$t_match = getMatchValue( "245", "a", \%norm, "tit", $config, $rec, $xpc );
		if ($flag{stit}) {
			$st_match = getMatchValue( "245", "b", \%norm, "stit", $config, $rec, $xpc );
		}
	} elsif ( hasTag( "246", $config, $rec, $xpc ) ) {
		$t_match = getMatchValue( "246", "a", \%norm, "tit", $config, $rec, $xpc );
		if ($flag{stit}) {
			$st_match = getMatchValue( "246", "b", \%norm, "stit", $config, $rec, $xpc );
		}
	}
	print $fh_report Dumper $t_match;
    print $fh_report Dumper $st_match;
    $total += ($t_match + $st_match);
	
	# compare year: check also if year diverges by 1
	my $y_exactmatch = 0;
	my $y_nearmatch  = 0;
    if ($flag{year}) {
    	if ( hasTag( "264", $config, $rec, $xpc ) ) {
    		$y_exactmatch = getMatchValue( "264", "c", \%norm, "year", $config, $rec, $xpc );
    		if ( $y_exactmatch == 0 ) {
    			$y_nearmatch = getMatchValue( "264", "c", \%norm, "year_p1", $config, $rec, $xpc );
    			if ( $y_nearmatch == 0 ) {
    				$y_nearmatch = getMatchValue( "264", "c", \%norm, "year_m1", $config, $rec, $xpc );
    			}
    		}
    	} elsif ( hasTag( "260", $config, $rec, $xpc ) ) {
    		$y_exactmatch = getMatchValue( "260", "c", \%norm, "year", $config, $rec, $xpc );
    		if ( $y_exactmatch == 0 ) {
    			$y_nearmatch = getMatchValue( "260", "c", \%norm, "year_p1", $config, $rec, $xpc );
    			if ( $y_nearmatch == 0 ) {
    				$y_nearmatch = getMatchValue( "260", "c", \%norm, "year_m1", $config, $rec, $xpc );
    			}
    		}
    	}
    }
	print $fh_report Dumper $y_exactmatch;
    print $fh_report Dumper $y_nearmatch;
    $total += ($y_exactmatch + $y_nearmatch);
    
    # check place and publisher
    my $pl_match = 0;
    my $pu_match = 0;
    if ($flag{place}) {
    	if ( hasTag( "264", $config, $rec, $xpc ) ) {
    		$pl_match = getMatchValue( "264", "a", \%norm, "place", $config, $rec, $xpc );
        } elsif ( hasTag( "260", $config, $rec, $xpc ) ) {
            $pl_match = getMatchValue( "260", "a", \%norm, "place", $config, $rec, $xpc );
        }
    }
    if ($flag{pub}) {
        if ( hasTag( "264", $config, $rec, $xpc ) ) {
            $pu_match = getMatchValue( "264", "b", \%norm, "pub", $config, $rec, $xpc );
        } elsif ( hasTag( "260", $config, $rec, $xpc ) ) {
            $pu_match = getMatchValue( "260", "b", \%norm, "pub", $config, $rec, $xpc );
        }
    }
	print $fh_report Dumper $pl_match;
    print $fh_report Dumper $pu_match;
    $total += ($pl_match + $pu_match);
    
	# check analytica for additional source info:
	my $src_match = 0;
	if ($flag{ana}) {
		if ( hasTag( "773", $config, $rec, $xpc ) && defined $norm{srctit} ) {
			$src_match = getMatchValue( "773", "t", \%norm, "srctit", $config, $rec, $xpc );
		} elsif ( hasTag( "500", $config, $rec, $xpc ) && defined $norm{src} ) {
			$src_match = getMatchValue( "500", "a", \%norm, "src", $config, $rec, $xpc );
		}
	}
	print $fh_report Dumper $src_match;
    $total += $src_match;
	
	# check material types and carrier
	my $mat_match = 0;
    my $car_match = 0;
	

	$mat_match = checkMaterial( \%norm, "doctype", $config, $rec, $xpc );
	if ( ( $mat_match == 0 ) && hasTag( "338", $config, $rec, $xpc ) ) {
		$car_match = getMatchValue( "338", "b", \%norm, "carrier", $config, $rec, $xpc );
	}  
	print $fh_report Dumper $mat_match;
    print $fh_report Dumper $car_match;
    $total += ($mat_match + $car_match);	  
    
	# check volume titles:
    my $tv_match = 0;
    my $av_match = 0;
    if ($flag{tvol}) {
        if ( hasTag( "505", $config, $rec, $xpc ) ) {
        	$tv_match = getMatchValue( "505", "t", \%norm, "tvol1", $config, $rec, $xpc );
        } elsif ( hasTag( "245", $config, $rec, $xpc ) ) {
            $tv_match = getMatchValue( "245", "a", \%norm, "tvol1", $config, $rec, $xpc );
        }
    }
    if ($flag{avol}) {
        if ( hasTag( "505", $config, $rec, $xpc ) ) {
            $av_match = getMatchValue( "505", "t", \%norm, "avol_tit", $config, $rec, $xpc );
        } elsif ( hasTag( "245", $config, $rec, $xpc ) ) {
            $av_match = getMatchValue( "245", "a", \%norm, "avol_tit", $config, $rec, $xpc );
            if ( $av_match == 0 ) {
                $av_match = getMatchValue( "245", "b", \%norm, "avol_tit", $config, $rec, $xpc );
            }
        }
    }  
	print $fh_report Dumper $tv_match;
    print $fh_report Dumper $av_match;
    $total += ($tv_match + $av_match);	
    
	# eliminate totally unsafe matches:
	if (($t_match == 0) && ($a1_match == 0)) {
		$total = 0;
		$unsafe = 1;
		
	}    
	print $fh_report "Subtotal: ". $total. "\n";
	if ($unsafe) {
		print $fh_report "UNSAFE MATCH - NEXT ___________________________ !!!!!!!!!!!!!!!!\n";
	}
    return $total, $unsafe;
          
}

=head2 SERVICE ROUTINES

=over 4

=item get_vars_from_csv() 

This function reads all rows from the csv file and returns it as separate variables.
rows a until s contain data that is needed for deduplication.
rows t, u, v (19-21) are not needed, these values come are mapped from a mapping file.

Arguments:
$currLine: CSV object (current csv line)

Returns: 
$row_a ... $row_s: strings

=back

=cut

sub get_vars_from_csv {

    my $currLine = shift;

    #get all necessary variables (row 20, 21 are not needed for dedup)
    my $row_a = $currLine->[0];     # author 1
    my $row_b = $currLine->[1];     # author 2 // author 3 is never needed
    my $row_d = $currLine->[3];     # title
    my $row_e = $currLine->[4];     # subtitle
    my $row_f = $currLine->[5];     # volume info 1
    my $row_g = $currLine->[6];     # volume info 2
    my $row_h = $currLine->[7];     # isbn
    my $row_i = $currLine->[8];     # pages
    my $row_j = $currLine->[9];     # material
    my $row_k = $currLine->[10];    # addendum
    my $row_l = $currLine->[11];    # location
    my $row_m = $currLine->[12];    # call number
    my $row_n = $currLine->[13];    # publisher place
    my $row_o = $currLine->[14];    # publisher name
    my $row_p = $currLine->[15];    # publication year
    my $row_q = $currLine->[16];    # subject code 1
    my $row_r = $currLine->[17];    # subject code 2
    my $row_s = $currLine->[18];    # subject code 3
	# rows 19-21 are not needed but will stay in the file.

    return (
        $row_a, $row_b, $row_d, $row_e, $row_f, $row_g,
        $row_h, $row_i, $row_j, $row_k, $row_l, $row_m,
        $row_n, $row_o, $row_p, $row_q, $row_r, $row_s
    );

}

=over 4

=item print_rep_header() 

This function prints a header for each entry in the debug report.

Arguments:
$filehandle, $database: strings, 
$docnumber: number

=back

=cut

sub print_rep_header {
    my $filehandle = shift;
    my $docnumber  = shift;
    my $database = shift;
    print $filehandle "\nNEW CSV LINE: #$docnumber  SRU: $database\n";
    print $filehandle "**************************************************\n";
}

=over 4

=item print_doc_header() 

This function prints a header for each document in the result set in the debug report.

Arguments:
$filehandle, $database: strings, 
$docnumber: number

=back

=cut


sub print_doc_header {
    my $filehandle = shift;
    my $docnumber  = shift;
    my $database   = shift;
    print $filehandle "\nDOCUMENT: #" . $docnumber . "  SRU: $database\n";
    print $filehandle "--------------------------------\n";
}

=over 4

=item print_progress() 

This function prints a progress bar on the output console: 
a * for every CSV line treated, every 100th line, the number is printed.

Arguments:
$progressnumber: number

=back

=cut


sub print_progress {
    my $progressnumber = shift;

    if ( $progressnumber % 100 != 0 ) {
        print "*";
    }
    else {
        print $progressnumber;
        print " \n";
    }
}

=over 4

=item build_base_url() 

This function builds the base url for the SRU query based on values from 
a config file.

Arguments:
$conf: configuration object

Return:
$base_url: string

=back

=cut

sub build_base_url {

    my $conf            = shift;
    my $server_endpoint = $conf->{sru}->{server_endpoint};
    my $record_schema   = $conf->{sru}->{record_schema};
    my $max_records     = $conf->{sru}->{max_records};
    my $query           = $conf->{sru}->{query};

    # important: recordPacking=xml is needed!
    my $base_url =
        $server_endpoint
      . "&operation=searchRetrieve&recordPacking=xml&recordSchema="
      . $record_schema
      . "&maximumRecords="
      . $max_records
      . "&query=";
    return $base_url;
}

=over 4

=item build_sruquery_basic() 

This function builds the first sru search (basic version)
based on either isbn or title/author or title/publisher combo.
It gets the response from the Server, loads the XML as DOM object 
and gets the XPATH context for a libxml dom.
The function also registers namespaces of xml if GVI is used.

Arguments:
$base_url: string, 
$conf: configuration object, 
$flag_ref, $esc_ref: hash references (%flag, %esc)

Return:
$xpathcontext: xpath object (xpc)

=back

=cut

sub build_sruquery_basic {

	my $base_url = shift;
	my $conf = shift;
	my $flag_ref = shift;
	my $esc_ref = shift;
	my $query = '';
	
	my %flag = %{$flag_ref};
	my %esc = %{$esc_ref};

	my $isbnquery 		= $conf->{sru}->{isbn_query};
	my $titlequery   	= $conf->{sru}->{title_query};
	my $authorquery   	= $conf->{sru}->{author_query};
	my $publisherquery  = $conf->{sru}->{publisher_query};
	my $yearquery 		= $conf->{sru}->{year_query};
	if ($flag{isbn1}) {
        $query = $base_url . $isbnquery . $esc{isbn};
    } else {
        $query = $base_url . $titlequery . $esc{tit};
        if ($flag{year}) {
        	$query .= "+AND" . $yearquery . $esc{year};
        }
        if ($flag{aut1}) {
            $query .= "+AND" . $authorquery . $esc{aut};
        } elsif ($flag{pub}) {
            $query .= "+AND" . $publisherquery . $esc{pub};
        }
    }

    print $fh_report Dumper $query;
    
    my $dom   = XML::LibXML->load_xml( location => $query );
    my $xpathcontext = XML::LibXML::XPathContext->new($dom);
    
    if ($query =~ /gvi/) {
		# important: register both namespaces:
    	$xpathcontext->registerNs( 'zs',  'http://www.loc.gov/zing/srw/' );
    	$xpathcontext->registerNs( 'rec', 'http://www.loc.gov/MARC21/slim' );
    }
    return $xpathcontext;
}

=over 4

=item build_sruquery_broad() 

This function builds the broad sru search using cql.all/anywhere
based on either title/author or title/publisher  or title/year combo.
It gets the response from the Server, loads the XML as DOM object 
and gets the XPATH context for a libxml dom.
The function also registers namespaces of xml if GVI is used.

Arguments:
$base_url: string, 
$conf: configuration object, 
$flag_ref, $esc_ref: hash references (%flag, %esc)

Return:
$xpathcontext: xpath object (xpc)

=back

=cut

sub build_sruquery_broad {

	my $baseurl = shift;
	my $conf = shift;
	my $flag_ref = shift;
	my $esc_ref = shift;

	my %flag = %{$flag_ref};
	my %esc = %{$esc_ref};
	my $query = '';	
	
	my $any_query = $conf->{sru}->{any_query};
	$query = $baseurl . $any_query . $esc{tit};
	if ($flag{aut1}) {
		$query .= "+AND" . $any_query . $esc{aut};
	} elsif ($flag{pub}) {
		$query .= "+AND" . $any_query . $esc{pub};
	} elsif ($flag{year}) {
        $query .= "+AND" . $any_query . $esc{year};
    }
    print $fh_report Dumper $query;
	
    my $dom   = XML::LibXML->load_xml( location => $query );
    my $xpathcontext = XML::LibXML::XPathContext->new($dom);
    
    if ($query =~ /gvi/) {
		# important: register both namespaces:
    	$xpathcontext->registerNs( 'zs',  'http://www.loc.gov/zing/srw/' );
    	$xpathcontext->registerNs( 'rec', 'http://www.loc.gov/MARC21/slim' );
    }
    return $xpathcontext;
}

=over 4

=item build_sruquery_narrow() 

This function builds the the narrow sru search
based on either title/author or title/publisher or title/year combo.
It gets the response from the Server, loads the XML as DOM object 
and gets the XPATH context for a libxml dom.
The function also registers namespaces of xml if GVI is used.

Arguments:
$base_url: string, 
$conf: configuration object, 
$flag_ref, $esc_ref: hash references (%flag, %esc)

Return:
$xpathcontext: xpath object (xpc)

=back

=cut

sub build_sruquery_narrow {
	
	my $baseurl = shift;
	my $conf = shift;
	my $flag_ref = shift;
	my $esc_ref = shift;

	my %flag = %{$flag_ref};
	my %esc = %{$esc_ref};
	my $query = '';	

	my $titlequery   	= $conf->{sru}->{title_query};
	my $authorquery   	= $conf->{sru}->{author_query};
	my $publisherquery  = $conf->{sru}->{publisher_query};
	my $any_query 		= $conf->{sru}->{any_query};
	my $year_query      = $conf->{sru}->{year_query};
		
	$query = $baseurl . $titlequery . $esc{tit};
	if ($flag{year}) {
		$query .= "+AND" . $year_query . $esc{year};
	}
	if ($flag{aut1}) {
		$query .= "+AND" . $authorquery . $esc{aut};
    } elsif ($flag{pub}) {
        $query .= "+AND" . $publisherquery . $esc{pub};
    } elsif ($flag{place}) {
        $query .= "+AND" . $any_query . $esc{place};
    } 
    print $fh_report Dumper $query;
	
    my $dom   = XML::LibXML->load_xml( location => $query );
    my $xpathcontext = XML::LibXML::XPathContext->new($dom);
    
    if ($query =~ /gvi/) {
		# important: register both namespaces:
    	$xpathcontext->registerNs( 'zs',  'http://www.loc.gov/zing/srw/' );
    	$xpathcontext->registerNs( 'rec', 'http://www.loc.gov/MARC21/slim' );
    }
    return $xpathcontext;	
}

=over 4

=item get_record_nrs() 

This function retrieves number of records from XPATH.

Arguments:
$xpathcontext: xpath object (xpc), 
$conf: configuration object

Return:
$numberofrecords: number

=back

=cut

sub get_record_nrs {

    my $xpathcontext = shift;
    my $conf = shift;
    my $nr_records = $conf->{sru}->{nr_records};
    my $numberofrecords;

    if ($xpathcontext->exists($nr_records) ) {
        $numberofrecords = $xpathcontext->findvalue($nr_records);
    } else {
    	# debug:
        print "xpc path not found! $ctr{line}\n";
        $numberofrecords = undef;
    }
    print $fh_report Dumper $numberofrecords;
    return $numberofrecords;
}

=over 4

=item get_xpc_nodes() 

This function gets nodes of records with XPATH into an array.

Arguments:
$xpath: xpath object (xpc), 
$conf: configuration object

Return:
@recordNodes: array 

=back

=cut

sub get_xpc_nodes {
    my $xpath = shift;
    my $conf = shift;
    my $record_node = $conf->{sru}->{record_node};
    my @recordNodes  = $xpath->findnodes($record_node);

    return @recordNodes;
}

=over 4

=item create_MARCXML() 

This function creates an xml file for export / re-import and adds subjects from original IFF data, 
based on the iff_subject_table.map. 


Arguments:
$record: record object, 
$hash_ref: hash reference (%subject_hash), 
$code 1, $code2, $code3: strings

Return:
XML string

=back

=cut

sub create_MARCXML {
	
    my $record = shift; 
    my $hash_ref = shift;
    my $code1 = shift;
    my $code2 = shift;
    my $code3 = shift;

    my $delete;
    my $append;
    my $subjectstring1 = '';
    my $subjectstring2 = '';
    my $subjectstring3 = '';
    my %subject_hash = %$hash_ref; 
    
    # create and add 690 fields with keywords 
    if (defined $code1 && $code1 !~/\A\Z/ && exists $subject_hash{"$code1 1"}) {
        $subjectstring1 = $subject_hash{"$code1 1"};
        if (exists $subject_hash{"$code1 2"}) {
            $subjectstring1 .= " : ".$subject_hash{"$code1 2"};
            if (exists $subject_hash{"$code1 3"})   { 
                $subjectstring1 .= " : ".$subject_hash{"$code1 3"};
            }
        }    
        $record->appendWellBalancedChunk('<datafield tag="690" ind1="H" ind2="D">
            <subfield code="8">'.$code1.'</subfield>
            <subfield code="a">'.$subjectstring1.'</subfield>
            <subfield code="2">HSG-IFF</subfield>
        </datafield>');       
        print $fh_report Dumper $subjectstring1;
    }
    
    if (defined $code2 && $code2 !~/\A\Z/) {
    	$subjectstring2 = $subject_hash{"$code2 1"};
    	if (exists $subject_hash{"$code2 2"}) {
            $subjectstring2 .= " : ".$subject_hash{"$code2 2"};
            if (exists $subject_hash{"$code2 3"})   { 
                $subjectstring2 .= " : ".$subject_hash{"$code2 3"};
            }
    	}         
    	$record->appendWellBalancedChunk('<datafield tag="690" ind1="H" ind2="D">
            <subfield code="8">'.$code2.'</subfield>
            <subfield code="a">'.$subjectstring2.'</subfield>
            <subfield code="2">HSG-IFF</subfield>
            </datafield>');     
        print $fh_report Dumper $subjectstring2;
    } 
    
    if (defined $code3 && $code3 !~/\A\Z/) {
        $subjectstring3 = $subject_hash{"$code3 1"};
        if (exists $subject_hash{"$code3 2"}) {
            $subjectstring3 .= " : ".$subject_hash{"$code3 2"};
            if (exists $subject_hash{"$code3 3"})   { 
                $subjectstring3 .= " : ".$subject_hash{"$code3 3"};
            }
        }  
        $record->appendWellBalancedChunk('<datafield tag="690" ind1="H" ind2="D">
            <subfield code="8">'.$code3.'</subfield>
            <subfield code="a">'.$subjectstring3.'</subfield>
            <subfield code="2">HSG-IFF</subfield>
            </datafield>');     
        print $fh_report Dumper $subjectstring3;
    }     
    
    return ($record->toString);
	
}

=over 4

=item printStatistics() 

This function prints final statistics in a log file.

Arguments:
$ctr_ref: hash reference (%ctr), 
$time: timestamp

=back

=cut

sub printStatistics {
	
	my $ctr_ref = shift;
	my $time = shift;
	my %ctr = %{$ctr_ref};		
	my $found = $ctr{found};
	my $notfound = $ctr{notfound};
	my $sru_noresults = $ctr{nohits};
	my $ignored = $ctr{ignore};
	my $journals = $ctr{journal};
	my $unsafe = $ctr{unsafe};
	my $iff_notfound = $ctr{iffnotfound};
	my $replace = $ctr{replace};
	my $reimport = $ctr{reimport};
	my $bestcase = $ctr{best};
	my $iffonly = $ctr{iffonly};
	my $totaldocs = $ctr{line};

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	my $timestamp = ($year+1900).'_'.($mon+1).'_'.$mday.'_'.$hour.'_'.$min;
	my $logfilename = 'log_'.$timestamp.'.txt';
	
	open my $log, ">:encoding(utf8)", $logfilename    or die "$logfilename: $!";
	
	print $log "Final Statistics: $timestamp\n--------------------------------------------------------\n";
	print $log "RECORDS PROCESSED:     $totaldocs\n";  
	print $log "TIME ELAPSED (sec)     "; printf $log ('%.2f',$time);
	print $log "\n";
	print $log "FOUND:         "; printf $log ('%.2f', $found/($totaldocs/100)); print $log "\% ($found)\n";
	print $log " - REPLACED:   "; printf $log ('%.2f', $replace/($totaldocs/100)); print $log "\% ($replace)\n";
	print $log " - REIMPORTED: "; printf $log ('%.2f', $reimport/($totaldocs/100)); print $log "\% ($reimport)\n";
	print $log " - BEST CASE:  "; printf $log ('%.2f', $bestcase/($totaldocs/100)); print $log "\% ($bestcase)\n";
	print $log "NOT FOUND:     "; printf $log ('%.2f', $notfound/($totaldocs/100)); print $log "\% ($notfound)\n";
	print $log " - IFF N/F:    "; printf $log ('%.2f', $iff_notfound/($totaldocs/100)); print $log "\% ($iff_notfound)\n";	
	print $log " - NO HITS:    "; printf $log ('%.2f', $sru_noresults/($totaldocs/100)); print $log "\% ($sru_noresults)\n";	
	print $log "IGNORED:       "; printf $log ('%.2f', $ignored/($totaldocs/100)); print $log "\% ($ignored)\n";
	print $log " - BLACKLIST:  "; printf $log ('%.2f', $journals/($totaldocs/100)); print $log "\% ($journals)\n";		
	print $log " - IFF ONLY:   "; printf $log ('%.2f', $iffonly/($totaldocs/100)); print $log "\% ($iffonly)\n";	
	print $log " - UNSAFE:     "; printf $log ('%.2f', $unsafe/($totaldocs/100)); print $log "\% ($unsafe)\n";

	close $log	or die "$logfilename: $!";
	print "\nStatistics: see $logfilename\n";
	
}


=over 4

=item list_of_journals() 

This function lists possible titles that indicate journals, yearbooks, legislative texts with difficult match criteria.
Records that match this list are blacklisted and excempted from dedup.

Return: 
$journaltitles: string

=back

=cut


sub list_of_journals {

    my @journal_keywords = (
        "Abgabenordnung..AO",
        "African Tax Systems",
        "Amtliche Sammlung",
        "Amtsbericht",
        "Amtsblatt",
        "Annual Report ....",
        "Appenzell A\. Rh\. Verwaltungspraxis",
        "Bereinigte Gesetzessammlung",
        "Bericht des Bundesrates zur Aussenwirtschaftspolitik",
        "Bericht zum Finanzplan des Bundes",
        "Budget .... de Canton Vaud",
        "Budget .... des eidgen.ssischen Standes Zug",
        "Budget Basel-Stadt",
        "Bundesfinanzen des Bundes",
        "Butterworths Orange Tax Handbook",
        "Butterworths Yellow Tax Handbook",
        "Cahiers de Droit Fiscal International",
        "Das aktuelle Steuerhandbuch",
        "Das schweizerische Energiekonzept\.",
        "Der Steuerentscheid",
        "Die direkte Bundessteuer .Wehrsteuer",
        "Die Eidgen.ssische Mehrwertsteuer..19",
        "Die eidg. Verrechnungssteuer",
        "Die Praxis der Bundessteuern",
        "Droit fiscal international de la Suisse",
        "Entscheide der Gerichts- und Verwaltungsbeh.rden",
        "Entscheide der Steuerrekurskommission",
        "Entscheidungen des Schweizerischen Bundesgerichts",
        "Entwicklung der Realsteuerhebes.tze der Gemeinden",
        "Entwicklung wesentlicher Daten der .ffentlichen Finanzwirtschaft",
        "European Tax Directory",
        "Finanzen der Schweiz",
        "Finanzplanung Appenzell Innerrhoden ....",
        "Fiskaleinnahmen des Bundes ....",
        "Galler Gemeindefinanzen",
        "Galler Steuerentscheide",
        "Gerichts- und Verwaltungsentscheide",
        "Gerichts- und Verwaltungspraxis",
        "Gesch.ftsbericht .... der Stadt",
        "Gesetzessammlung Neue Reihe",
		"Grunds.tzliche Entscheide des Solothurnischen Kantonalen Steuergerichts",
        "Handbuch der Finanzwissenschaft",
        "Handbuch Internationale Verrechnungspreise",
        "IFF Referenten- und Autorenforum",
        "IFSt-Schrift",
        "IFSt-Brief",
        "IFSt-Heft",
        "Internationale Steuern",
        "Internationales Steuerrecht der Schweiz",
        "Internationales Steuer-Lexikon",
        "Jahresbericht ..",
        "[j|J]ahrbuch",
        "[j|J]ournal",
        "Kantonalen Rekurskommission",
        "Kantonsfinanzen\/Finances des cantons",
        "Kommunale Geb.hrenhaushalte",
        "Kommentar zum Einkommensteuergesetz EStG",
        "Kommentar zum Z.rcher Steuergesetz",
        "Landesplanerische Leitbilder der Schweiz",
        "Model Tax Convention on Income and on Capital",
        "Orange Tax Guide",
        "Praxis des Verwaltungsgerichts",
        "Public Management Developments",
        "Rechenschaftsbericht",
        "Rechnung Basel-Stadt f.r das Jahr",
        "Rechnung .... der Stadt",
        "Rechnung .... des Kantons",
        "Rechnung f.r den Staat",
        "Research in Governmental and Nonprofit Accounting",
        "Residence of Individuals under Tax Treaties and EC Law",
        "Sammlung der Entscheidungen des Bundesfinanzhofs",
        "Sammlung der Verwaltungsentscheide",
        "Schweizerisches Steuer-Lexikon",
        "Staatsrechnung ",
        "Steuerbelastung in der Schweiz\.",
        "St.Galler Seminar .... .ber Unternehmungsbesteuerung",
        "St.Galler Seminar .... zur Unternehmungsbesteuerung",
        "St.Galler Steuerbuch",
        "Swiss-U.S. Income Tax Treaty",
        "Taxation and Investment in Central & East European Countries",
        "Thurgauische Verwaltungsrechtspflege",
        "Umsatzsteuergesetz",
        "Vertr.ge zur Gr.ndung der Europ.ischen Gemeinschaften",
        "Verwaltungspraxis der Bundesbeh.rden",
        "Verwaltungs- und Verwaltungsgerichtsentscheide",
        "Voranschlag",
        "Wirtschaft und Finanzen im Ausland",
        "[y|Y]earbook",
        "Zwischenstaatliche Belastungs- und Strukturvergleiche",
        "Z.rcher Steuerbuch"
    );

    my $journaltitles = join "|", @journal_keywords;
    return $journaltitles;
}


=over 4

=item build_subject_table() 

Function to build subject table: (c) Felix Leu 2018
Read a map file with all possible subject combinations from IFF institute and build hash accordingly. 
Example: $subj_hash{'1 GB'} is 'Finanzrecht'

Return: 
%subject_hash: hash with subject keys and subject strings.

=back

=cut

sub build_subject_table {
	
	my $subj_map    = "iff_subject_table.map";
	my %subject_hash   = ();        
	open(MAP, "<$subj_map") or die "Cannot open file $subj_map \n";
	binmode (MAP, ':encoding(iso-8859-1)');   
	while (<MAP>) {
	   my ($level, $code, $subject) = /^(\S+)\s+(\S+)\s+(.*)$/;
	   
	   $subject_hash{"$code $level"}  = decode('iso-8859-1', $subject);      
	}
	close MAP;
	return %subject_hash;
	
}

=over 4

=item remove_bom() 

Function removes the BOM (Microsoft fileheader for Unicode) from the first value in the first line.

Argument:
$var: string 

Return: 
$var: string

=back

=cut

sub remove_bom {
	my $var = shift;

	$var =~ s/\xEF\xBB\xBF//;
	$var =~ s/^\x{FEFF}//;
	$var =~ s/^\x{feff}//;
	$var =~ s/^\N{U+FEFF}//;
	$var =~ s/^\N{ZERO WIDTH NO-BREAK SPACE}//;
	$var =~ s/^\N{BOM}//; 

	return $var;
}

=over 4

=item prepare_export() 

Function prepares the export array:
add a row [22] to the current csv line with the selected export message
if defined, add row [23] with the iff docnr. to be replaced
if defined, add row [24] with the best match docnr. 
add the line to the export array. 

Argument:
$l: CSV object ($line), 
$e_ref: array reference, 
$RESULT: string, 
$bestmatch: string, 
$replacenr: string, 

Return: 
@e: array (export)

=back

=cut

sub prepare_export {
	my $l = shift;
	my $e_ref = shift;
	my $RESULT = shift;
	my $bestmatch = shift;
	my $replacenr = shift;
	
	my @e = @{ $e_ref };
	print $fh_report Dumper $RESULT;	
	print $fh_report Dumper $bestmatch;
	$l->[22] = "$RESULT";
	# first: possible iff record to replace
	if (defined $replacenr) {
		$l->[23] = $replacenr
	}
	# second: recordnumber to import
	if (defined $bestmatch) {
		$l->[24] = $bestmatch
	}

    push @e, $l;
    return @e;
	
}

=over 4

=item print_hash() 

Function prints a hash for debugging.

Argument:
$hash_ref: hash reference, 
$fh: filehandle

=back

=cut

sub print_hash {
	
	my $hash_ref = shift;
	my $fh = shift;
	my %hash = %{$hash_ref};
	
	foreach my $key (keys %hash) {
        print $fh "$key: $hash{$key}\n"   if defined $hash{$key};
	}
}

=over 4

=item print_help() 

Function prints a little helptext if script is called without options or with option -h.

=back

=cut

sub print_help {
	print "--------------------------------------------------\n";
	print "Usage: dedup.pl [-c config] [-f file] [-h]\n";
	print "Parameters:  \n";
	print "-c    desired SRU / matching configuration (gvi or swissbib)\n";
	print "-f    input data file (csv format, more info: readme.txt)\n";
	print "-h    little help text\n";

	print "Some data files are in directory ./data/ for testing\n";
	print "Example: perl dedup.pl -c gvi -f data/test1526.csv \n";

}




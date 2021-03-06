#!/usr/bin/perl
#
# @File dedup.pl
# @Author Kathrin Heim
# @Created 06.07.2019 
# Perl script for data deduplication by SRU service
# Documentation: see ./readme.txt

use strict;
use warnings;
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

# ----
# DECLARATION OF GLOBAL VARIABLES for dedup.pl
# ----

# start timer:
my $starttime = time();

# Create a config and open config file:
my $config = Config::Tiny->new;
$config = Config::Tiny->read('app.conf');

# global config values:
my $base_url  = build_base_url($config);
my $window    = $config->{sru}->{max_records};
my $m_safe    = $config->{match}->{safe};

# get a file with records from command line:
my $datafile;
if ( $#ARGV >= 0 ) {
    $datafile = $ARGV[0];
} else {
    print "Usage: Call this perl program with an input file:\n Example: dedup.pl data/test1526.csv \n";
    exit;
}

# import and export variables:
my $line;            # a data line from csv file
my @export;          # array for export data
my @bestmatch;       # array for best matching record

# counters for input, ignored, not found, found and unsafely matched records:
$_ = '0' for my ($line_ctr, $ign_ctr, $nf_ctr, $f_ctr, $uns_ctr);

# build subject hash
my %subj_hash = build_subject_table();

# get difficult titles
my $trouble_titles = list_of_journals();

# create a new csv object:
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

    $line_ctr++;
    printReportHeader( $fh_report, $line_ctr );
    printProgressBar($line_ctr);
    $bestmatch[0] = 0; 
    my ( $aut1,  $aut2, $tit,  $stit,  $v1,    $v2,  $isbn,  $pag,  $mat,  $add,   $loc,   $callno,
        $place, $pub,  $year, $code1, $code2, $code3  ) = getVariablesFromCsv($line);      
 
    if ($line_ctr == 1) {
    	$aut1 = removeBOM($aut1);
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

    if ( ( $code1 =~ /^Z/ ) || ( $mat =~ /CD-ROM|online/ ) || ( $norm{tit} =~ m/$trouble_titles/i ) )    {
        @export = prepare_export($line, \@export, "ignore");
        $ign_ctr++;
        next;
    }

    # ----
    # start search: build sru query, escape title & author strings
    # ----
    
    my @records;
    my %esc;     # escaped search terms
    ($esc{isbn}, $esc{year}, $esc{tit}, $esc{aut}, $esc{pub}, $esc{place}) = clean_search_params(\%norm, \%flag);

    my $sruquery = build_sruquery_basic($base_url, $config, \%flag, \%esc);
    my $xpc = get_xpc($sruquery);
    my $resultSetNo = get_recordNumbers($xpc);
    print $fh_report Dumper( $sruquery, $resultSetNo );

    if ( $resultSetNo == 0 ) {
    	# try a different search query with broader parameters, otherwise next;
    	$sruquery = build_sruquery_broad($base_url, $config, \%flag, \%esc);
        $xpc      = get_xpc($sruquery);
        $resultSetNo = get_recordNumbers($xpc);
        print $fh_report Dumper( $sruquery, $resultSetNo );
        if ( $resultSetNo == 0 || $resultSetNo >= $window ) {
            @export = prepare_export($line, \@export, "notfound");
            $nf_ctr++;
            next;
        } else {
            @records = get_xpc_nodes($xpc);
        }
    } elsif ( $resultSetNo >= $window ) {

        # try a different search with narrower parameters, otherwise next;
        $sruquery = build_sruquery_narrow($base_url, $config, \%flag, \%esc);
        $xpc      = get_xpc($sruquery);
        $resultSetNo = get_recordNumbers($xpc);
        print $fh_report Dumper( $sruquery, $resultSetNo );
        if ( $resultSetNo == 0 || $resultSetNo >= $window ) {
            @export = prepare_export($line, \@export, "notfound");
            $nf_ctr++;
            next;
        } else {
            @records = get_xpc_nodes($xpc);
        } 
    } else {
        @records = get_xpc_nodes($xpc);
    }

    # -------------
    # start comparing the results: loop through result set
    # -------------

    my $i = 0;
    foreach my $rec (@records) {
        $i++;
        printDocumentHeader( $fh_report, $i );
        my $sysno = getControlfield( '001', $rec, $xpc );
        
        my $total = evaluate_records(\%flag, \%norm, $config, $rec, $xpc);
        print "$line_ctr: $i: $total\n";    

        # check if this is currently the best match and safe the record:
        if ( $total > $bestmatch[0]){ 
            @bestmatch = (); #clear @bestmatch
            push @bestmatch, $total, $sysno, $rec;
            print $fh_report "NEW BEST MATCH: $total\n";
        }

    } # end of foreach loop (going through each record in results list)
	
    print $fh_report "Bestmatch: $bestmatch[0], Bestrecordnr: $bestmatch[1] \n";
    
    # ----------------
    # handle best result:
    # ----------------
     
    if ($bestmatch[0] >= $m_safe) {
        @export = prepare_export($line, \@export, "found", $bestmatch[1]);
        $f_ctr++;
        my $xml = createMARCXML($bestmatch[2], \%subj_hash, $code1, $code2, $code3);		                    
        print $fh_XML $xml;        
        
    } else {
        @export = prepare_export($line, \@export, "unsafe");
        $uns_ctr++;      
    }
    
} # end of while loop (going through every input line)

# --------------------------
# Finish: create output, count time, create statistics
# --------------------------

# print last xml line
print $fh_XML '</data>';

# print export file
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

printStatistics($f_ctr, $nf_ctr, $ign_ctr, $uns_ctr, $line_ctr, $timeelapsed);



######################################################################################
# ------------------------------------------------------------------------------------
# SUBROUTINES for dedup.pl
# ------------------------------------------------------------------------------------

# 1) NORMALIZATION ROUTINES:
# ------------------------------------------------------------------------------------

# -----
# function normalize_isbn() normalizes isbn numbers, checks if one or two isbn are present,
# sets flags and returns the normalized isbn and flags.
# argument: isbn
# returns: normalized isbn(s) and flag(s)
# -----

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

# -----
# function normalize_author() normalizes authors, checks for authorities,
# sets flags and returns the normalized authors and flags.
# argument: author variable
# returns: normalized author and flag
# -----

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

# -----
# function check_addendum() checks addendum for volume information,
# sets flags and returns the volume information and flags.
# argument: addendum variable
# returns: volume title, volume number and flag
# -----

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

# -----
# function check_analytica() checks if there is source information for an analyticum
# in the addendum.
# argument: addendum
# returns: analytica flag, citation, source title, source author
# -----

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

# -----
# function normalize_title() normalizes the title,
# and returns the title
# argument: title
# returns: title
# -----

sub normalize_title {

    my $originalTitle = shift;

    $originalTitle =~ s/^L\'//g;    #remove L' in the beginning
    $originalTitle =~
      s/eidg\./eidgen\xf6ssischen/i;    #replace with correct umlaut
    $originalTitle =~ s/st\.gall/st gall/i;
    $originalTitle = trim($originalTitle);    # remove whitespaces
    return $originalTitle;
}

# -----
# function check_subtitles() checks rows subtitle, volume1 and volume2
# for sensible information, sets flag accordingly
# and normalizes the strings.
# arguments: subtitle, title volume information
# returns: subtitle flag, subtitle, volume flag, volumes
# -----

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

# -----
# function normalize_year() ensures that the year variable contains
# four digits and selects the latest year.
# It calculates the year-range for the sru query (one year above and below original value).
# arguments: year
# returns: flag for year, year-plus-one, year-minus-one
# -----

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

# -----
# function check_ppp() checks if pages, publisher and place contain information.
# it also checks if pages contain a range and are therefore analytica.
# argument: pages, publisher, place
# return: flags for pagerange, publisher, place
# -----

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
# ----
# function deals with diverse material codes and returns correct type and changes some flags.
# ----

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
        $type  = qr/m|i/;            # doctype can be both.
    }
	if ( $year =~ /online/i ) {
        $material = "online";
    }
    return ($type, $flag{ana}, $flag{isbn1}, $flag{isbn2}, $flag{year}, $material);
	
}
                  




# -----
# function clean_search_params() tidies the normalized title/author strings
# and escapes them for the sru query building.
# argument: normalized title or author strings
# retunrns: escaped title or author string

sub clean_search_params {
	
	my $norm_ref = shift;
	my $flag_ref = shift;
	my %norm = %{$norm_ref};
	my %flag = %{$flag_ref};
	my $CLEAN_TROUBLE_CHAR = qr/\.|\(|\)|\'|\"|\/|\+|\[|\]|\?| and | or /;    #clean characters: .()'"/+[]? and remove and / or
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
    $escaped_title = uri_escape_utf8($escaped_title);
    
	if ($flag{aut1}) {
	    $escaped_author = $norm{aut1};
		$escaped_author =~ s/$CLEAN_TROUBLE_CHAR//g;
    	$escaped_author = uri_escape_utf8($escaped_author); 
	} else {
		$escaped_author = '';
	}
	
	if ($flag{pub}) {
	    $escaped_publisher = $norm{pub};
		$escaped_publisher =~ s/$CLEAN_TROUBLE_CHAR//g;
	    $escaped_publisher = uri_escape_utf8($escaped_publisher); 		
	} else {
		$escaped_publisher = '';
	}
	
	if ($flag{place}) {
		$escaped_place = $norm{place};
		$escaped_place =~ s/$CLEAN_TROUBLE_CHAR//g;
    	$escaped_place = uri_escape_utf8($escaped_place); 
	} else {
		$escaped_place = '';
	}
    
    return ($escaped_isbn, $escaped_year, $escaped_title, $escaped_author, $escaped_publisher, $escaped_place );

}

# 2) MATCH ROUTINES:
# --------------------------------------------------------------------------------------

# ----
# getControlfield checks if a specific MARC controlfield exists and returns its content.
# argument: MARC controlfield number, current record node, current xpath context
# returns:  controlfield content (string or undef)
# ----

sub getControlfield {
    my $controlfield_nr = shift;
    my $record          = shift;
    my $xpath           = shift;
    my $controlfield_content;

    if (
        $xpath->exists(
            './rec:controlfield[@tag=' . $controlfield_nr . ']', $record
        )
      )
    {

        foreach my $el (
            $xpath->findnodes(
                './rec:controlfield[@tag=' . $controlfield_nr . ']', $record
            )
          )
        {
            $controlfield_content = $el->to_literal;

            #print $fh_report Dumper ($controlfield_nr, $controlfield_content);
        }
    }
    else {
        $controlfield_content = undef;
    }
    return $controlfield_content;
}

# ----
# hasTag checks if a MARC field (datafield) exists.
# argument: MARC field number
# returns:  1 (true) or 0 (false)
# ----

sub hasTag {
    my $tag          = shift;    # Marc tag
    my $record       = shift;    # record node
    my $xpathcontext = shift;    # xpc

    if (
        $xpathcontext->exists( './rec:datafield[@tag=' . $tag . ']', $record ) )
    {
        #debug
        return 1;
    }
    else {
        return 0;
    }

}

# ----DELETE?
# hasCode checks if a MARC subfield exists.
# argument: MARC subfield code
# returns:  1 (true) or 0 (false)
# ----

sub hasCode {
    my $code         = shift;   # subfield code
    my $record       = shift;    # record node
    my $xpathcontext = shift;    # xpc

    if ($xpathcontext->exists( './rec:subfield[@code="' . $code . '"]', $record ) ){
        #debug
        print "hascode returned 1!\n";
        return 1;
    }
    else {
        return 0;
    }

}

# ----
# function checkIsbnMatch() to check if ISBN numbers match.
# arguments: current record, current XPATH, isbn number from original data
# returns: match value
# -----

sub checkIsbnMatch {
    my $record        = shift;
    my $xpath         = shift;
    my $original_isbn = shift;
    my $config        = shift;
    my $isbn_match    = $config->{match}->{isbn};
    my $matchvalue    = 0;

    foreach my $el ( $xpath->findnodes( './rec:datafield[@tag=020]', $record ) ) {
        my $marc_20_a = $xpath->findnodes( './rec:subfield[@code="a"]', $el )->to_literal;
        $marc_20_a =~ s/[^0-9xX]//g;
        print $fh_report "020 a $marc_20_a\n";

        if ( $original_isbn =~ m/$marc_20_a/i ) {
            $matchvalue += $isbn_match;
        }
    }
    return $matchvalue;
}

# ------
# sub getMatchValue() compares the content of a MARC field to an original string
# and returns a positive or negative match value.
# arguments: MARC field and subfield, string to compare against, match value, context
# returns: match value
# ------

sub getMatchValue {
    my $datafield      = shift;
    my $subfield       = shift;
    my $hash_ref       = shift;
    my $key            = shift;
    my $config         = shift;

    my $record         = shift;
    my $xpath          = shift;
    my %norm 		   = %{$hash_ref};
    my $originalstring = $norm{$key};
   	my $matchvalue     = $config->{match}->{$key};
    my $CLEAN_TROUBLE_CHAR = qr/\.|\(|\)|\'|\"|\/|\+|\[|\]|\?/; #clean following characters: .()'"/+[]?
    
    if (defined $originalstring ) {
    	# continue with comparison
    	foreach my $el ( $xpath->findnodes('./rec:datafield[@tag="' . $datafield . '"]', $record  ) ) {
   			my $marcfield = $xpath->findnodes( './rec:subfield[@code="' . $subfield . '"]', $el )->to_literal;
        	$marcfield =~ s/$CLEAN_TROUBLE_CHAR//g;    # clean fields from special characters
	        if ( $marcfield =~ /\A\Z/ ) {
	            # subfield is empty and therefore does not exist:
	            return 0;
	        } else {
	        	print $fh_report "$datafield $subfield $marcfield\n";
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

# -----
# checkMaterial() checks the LDR field in the MARC record,
# cuts aut position 07 and compares it to the doctype.
# arguments: doctype, matchvalue, $rec, $xpc
# return: matchvalue
# -----
sub checkMaterial {
	my $hash_ref = shift;
    my $type     = shift;
    my $posmatch = shift;
    my $record   = shift;
    my $xpath    = shift;
    my $ldr;
    my $matchvalue;
    my %norm = %{$hash_ref};

    if ( $xpath->exists( './rec:leader', $record ) ) {
        foreach my $el ( $xpath->findnodes( './rec:leader', $record ) ) {
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

# ----
# checkNetwork($config, $rec, $xpc);
# ----

sub checkNetwork {
    my $conf   = shift;
    my $record = shift;
    my $xpath  = shift;
    my $MARC035a;

    # which network should be ranked how? get values from conf.
    my $bsz             = $conf->{net}->{BSZ};
    my $bvb             = $conf->{net}->{BVB};
    my $gbv             = $conf->{net}->{GBV};
    my $kobv            = $conf->{net}->{KOBV};
    my $hbz             = $conf->{net}->{HBZ};
    my $heb             = $conf->{net}->{HEBIS};
    my $dnb             = $conf->{net}->{DNB};
    my $obv             = $conf->{net}->{OBV};
    my $matchvalue      = 0;
    my $addedmatchvalue = 0;
    my $m035_counter    = 0;

    foreach
      my $el ( $xpath->findnodes( './rec:datafield[@tag=035 ]', $record ) )
    {
        $MARC035a =
          $xpath->findnodes( './rec:subfield[@code="a"]', $el )->to_literal;
        if ( $MARC035a =~ /OCoLC/ ) {

            # ignore, not relevant
        }
        else {
            print $fh_report "035 a " . $MARC035a . "\n";
            $m035_counter++;
            if (   $MARC035a =~ /BSZ/
                || $MARC035a =~ /DE-627/
                || $MARC035a =~ /DE-576/
                || $MARC035a =~ /DE-615/ )
            {
                $matchvalue = $bsz;
            }
            elsif ( $MARC035a =~ /BVB/ || $MARC035a =~ /DE-604/ ) {
                $matchvalue = $bvb;
            }
            elsif ( $MARC035a =~ /GBV/ ) {
                $matchvalue = $gbv;
            }
            elsif ( $MARC035a =~ /HBZ/ || $MARC035a =~ /DE-605/ ) {
                $matchvalue = $hbz;
            }
            elsif ( $MARC035a =~ /HEB/ || $MARC035a =~ /DE-603/ ) {
                $matchvalue = $heb;
            }
            elsif ($MARC035a =~ /DNB/
                || $MARC035a =~ /DE-101/
                || $MARC035a =~ /ZDB/ )
            {
                $matchvalue = $dnb;
            }
            elsif ( $MARC035a =~ /KBV/ ) {
                $matchvalue = $kobv;
            }
            elsif ( $MARC035a =~ /OBV/ ) {
                $matchvalue = $obv;
            }
            else {
                #print "Unbekanntes Netzwerk! $MARC035a\n";
                $matchvalue = 0;
            }
            print $fh_report Dumper $matchvalue;
            $addedmatchvalue += $matchvalue;
        }
    }
    return ( $m035_counter, $addedmatchvalue );
}

#----
# main sub which deals with all the matching for each record in result set
# arguments: reference for hashes flag and norm, record & xpath object, config
# returns: total match value
# ----

sub evaluate_records {
	
	my $flag_ref = shift;
	my $norm_ref = shift;
	my $config = shift;
	my $rec = shift;
	my $xpc = shift;
    my %norm = %{$norm_ref};
    my %flag = %{$flag_ref};
    my $total = 0;
    
    # compare ISBN:
    my $i_match = 0;
    if ( $flag{isbn1}  && ( hasTag( "020", $rec, $xpc ) ) ) {
    	$i_match = checkIsbnMatch( $rec, $xpc, $norm{isbn1}, $config);
    }
    if ( $flag{isbn2}  && ( hasTag( "020", $rec, $xpc ) ) ) {
        $i_match += checkIsbnMatch( $rec, $xpc, $norm{isbn2}, $config);
    }
    print $fh_report Dumper $i_match;
    $total += $i_match;
    
    # compare Author/Authority/other associated persons
   	my $a1_match = 0;
	my $a2_match = 0;
	if ($flag{aut1}) {
		if ( hasTag( "100", $rec, $xpc ) ) {
			$a1_match = getMatchValue( "100", "a", \%norm, "aut1", $config, $rec, $xpc );
        } elsif ( hasTag( "700", $rec, $xpc ) ) {
			$a1_match = getMatchValue( "700", "a", \%norm, "aut1", $config, $rec, $xpc );
		} elsif ( hasTag( "110", $rec, $xpc ) ) {
            $a1_match = getMatchValue( "110", "a", \%norm, "aut1", $config, $rec, $xpc );
        } elsif ( hasTag( "710", $rec, $xpc ) ) {
            $a1_match = getMatchValue( "710", "a", \%norm, "aut1", $config, $rec, $xpc );
        }
    }
    if ($flag{aut2}) {
    	if ( hasTag( "100", $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "100", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "700", $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "700", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "110", $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "110", "a", \%norm, "aut2", $config, $rec, $xpc );
    	} elsif ( hasTag( "710", $rec, $xpc ) ) {
    		$a2_match = getMatchValue( "710", "a", \%norm, "aut2", $config, $rec, $xpc );
    	}
    }
    print $fh_report Dumper $a1_match;
    print $fh_report Dumper $a2_match;
    $total += ($a1_match + $a2_match);
    
	# compare title & subtitle fields
	my $t_match  = 0;
	my $st_match = 0;
	if ( hasTag( "245", $rec, $xpc ) ) {
		$t_match = getMatchValue( "245", "a", \%norm, "tit", $config, $rec, $xpc );
		if ($flag{stit}) {
			$st_match = getMatchValue( "245", "b", \%norm, "stit", $config, $rec, $xpc );
		}
	} elsif ( hasTag( "246", $rec, $xpc ) ) {
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
    	if ( hasTag( "264", $rec, $xpc ) ) {
    		$y_exactmatch = getMatchValue( "264", "c", \%norm, "year", $config, $rec, $xpc );
    		if ( $y_exactmatch == 0 ) {
    			$y_nearmatch = getMatchValue( "264", "c", \%norm, "year_p1", $config, $rec, $xpc );
    			if ( $y_nearmatch == 0 ) {
    				$y_nearmatch = getMatchValue( "264", "c", \%norm, "year_m1", $config, $rec, $xpc );
    			}
    		}
    	} elsif ( hasTag( "260", $rec, $xpc ) ) {
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
    	if ( hasTag( "264", $rec, $xpc ) ) {
    		$pl_match = getMatchValue( "264", "a", \%norm, "place", $config, $rec, $xpc );
        } elsif ( hasTag( "260", $rec, $xpc ) ) {
            $pl_match = getMatchValue( "260", "a", \%norm, "place", $config, $rec, $xpc );
        }
    }
    if ($flag{pub}) {
        if ( hasTag( "264", $rec, $xpc ) ) {
            $pu_match = getMatchValue( "264", "b", \%norm, "pub", $config, $rec, $xpc );
        } elsif ( hasTag( "260", $rec, $xpc ) ) {
            $pu_match = getMatchValue( "260", "b", \%norm, "pub", $config, $rec, $xpc );
        }
    }
	print $fh_report Dumper $pl_match;
    print $fh_report Dumper $pu_match;
    $total += ($pl_match + $pu_match);
    
	# check analytica for additional source info:
	my $src_match = 0;
	if ($flag{ana}) {
		if ( hasTag( "773", $rec, $xpc ) && defined $norm{srctit} ) {
			$src_match = getMatchValue( "773", "t", \%norm, "srctit", $config, $rec, $xpc );
		} elsif ( hasTag( "500", $rec, $xpc ) && defined $norm{src} ) {
			$src_match = getMatchValue( "500", "a", \%norm, "src", $config, $rec, $xpc );
		}
	}
	print $fh_report Dumper $src_match;
    $total += $src_match;
	
	# check material types and carrier
	my $mat_match = 0;
    my $car_match = 0;
	$norm{carrier} = 'nc'; # carrier type code for printed volume (= documents in input file)
    my $mat_conf  = $config->{match}->{material};

	$mat_match = checkMaterial( \%norm, "doctype", $mat_conf, $rec, $xpc );
	if ( ( $mat_match == 0 ) && hasTag( "338", $rec, $xpc ) ) {
		$car_match = getMatchValue( "338", "b", \%norm, "carrier", $config, $rec, $xpc );
	}  
	print $fh_report Dumper $mat_match;
    print $fh_report Dumper $car_match;
    $total += ($mat_match + $car_match);	  
    
	# check volume titles:
    my $tv_match = 0;
    my $av_match = 0;
    if ($flag{tvol}) {
        if ( hasTag( "505", $rec, $xpc ) ) {
        	$tv_match = getMatchValue( "505", "t", \%norm, "tvol1", $config, $rec, $xpc );
        } elsif ( hasTag( "245", $rec, $xpc ) ) {
            $tv_match = getMatchValue( "245", "a", \%norm, "tvol1", $config, $rec, $xpc );
        }
    }
    if ($flag{avol}) {
        if ( hasTag( "505", $rec, $xpc ) ) {
            $av_match = getMatchValue( "505", "t", \%norm, "avol_tit", $config, $rec, $xpc );
        } elsif ( hasTag( "245", $rec, $xpc ) ) {
            $av_match = getMatchValue( "245", "a", \%norm, "avol_tit", $config, $rec, $xpc );
            if ( $av_match == 0 ) {
                $av_match = getMatchValue( "245", "b", \%norm, "avol_tit", $config, $rec, $xpc );
            }
        }
    }  
	print $fh_report Dumper $tv_match;
    print $fh_report Dumper $av_match;
    $total += ($tv_match + $av_match);	
    
    # Get 035 Field number and check for best network (origin)
    my $m035_counter = 0;
    my $nw_match     = 0;
    if ( hasTag( "035", $rec, $xpc ) ) {
    	( $m035_counter, $nw_match ) = checkNetwork( $config, $rec, $xpc );
    } 
	print $fh_report Dumper $m035_counter;
    print $fh_report Dumper $nw_match;
    $total += ($m035_counter + $nw_match);   
    
	# eliminate totally unsafe matches:
	if (($t_match == 0) && ($a1_match == 0)) {
		$total = 0;
		print $fh_report "@@@ Unsafe Match author-title! \n"
	}    
	print $fh_report Dumper $total;
    return $total;
          
}

# SERVICE ROUTINES:

# ------------
# reads all rows from the csv file and returns it as separate variables.
# rows a until s contain data that is needed for deduplication.
# rows t, u, v (19-21) are not needed, these values come are mapped from a mapping file.
# argument: csv line
# return: rows A - S

sub getVariablesFromCsv {

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

# -----
# prints a header for each entry in the debug report
# argument: line counter and filehandle
# -----

sub printReportHeader {
    my $filehandle = shift;
    my $docnumber  = shift;
    print $filehandle "\nNEW CSV LINE: #$docnumber\n";
    print $filehandle "**************************************************\n";
}

# -----
# prints a header for each document in the result set in the debug report
# argument: doc counter and filehandle
# -----

sub printDocumentHeader {
    my $filehandle = shift;
    my $docnumber  = shift;
    print $filehandle "\nDOCUMENT: #" . $docnumber . "\n";
    print $filehandle "--------------------------------\n";
}

# -----
# prints a progress bar on the console: a * for every CSV line treated,
# every 100th line, the number is printed.
# argument: line counter
# -----

sub printProgressBar {
    my $progressnumber = shift;

    if ( $progressnumber % 100 != 0 ) {
        print "*";
    }
    else {
        print $progressnumber;
        print " \n";
    }
}

# -----
# this function builds the base url for the SRU query based on values from
# a config file.
# arguments: config file object
# returns: base url string
# -----

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

# ----
# build_sruquery_basic () builds the first sru search (basic version)
# based on either isbn or title/author or title/publisher combo.
# arguments: configuration, flags and normalized search values.
# returns: query string
# ----

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
	if ($flag{isbn1}) {
        $query = $base_url . $isbnquery . $esc{isbn};
    } else {
        $query = $base_url . $titlequery . $esc{tit};
        if ($flag{aut1}) {
            $query .= "+AND" . $authorquery . $esc{aut};
        } elsif ($flag{pub}) {
            $query .= "+AND" . $publisherquery . $esc{pub};
        }
    }
    return $query;
}

# ----
# build_sruquery_broad () builds the broad sru search using cql.all/anywhere
# based on either title/author or title/publisher or title/year combo.
# arguments: configuration, flags and normalized search values.
# returns: query string
# ----

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
    return $query;
}

# ----
# build_sruquery_narrow () builds the narrow sru search using 
# based on either title/author or title/publisher or title/year combo.
# arguments: configuration, flags and normalized search values.
# returns: query string
# ----

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
		
	$query = $baseurl . $titlequery . $esc{tit};
	if ($flag{aut1}) {
		$query .= "+AND" . $authorquery . $esc{aut};
    } elsif ($flag{pub}) {
        $query .= "+AND" . $publisherquery . $esc{pub};
    } elsif ($flag{place}) {
        $query .= "+AND" . $any_query . $esc{place};
    } elsif ($flag{year}) {
        $query .= "+AND" . $any_query . $esc{year};
    }
    return $query;
	
}

# -----
# get_xpc loads xml as DOM object and gets the XPATH context for a libxml dom, registers namespaces of xml
# argument: sru query
# returns: xpath object (xpc)
# -----

sub get_xpc {
	
    my $query = shift;
    my $dom   = XML::LibXML->load_xml( location => $query );
    my $xpathcontext = XML::LibXML::XPathContext->new($dom);

    # important: register both namespaces:
    $xpathcontext->registerNs( 'zs',  'http://www.loc.gov/zing/srw/' );
    $xpathcontext->registerNs( 'rec', 'http://www.loc.gov/MARC21/slim' );
    return $xpathcontext;
}

# -----
# retrieves number of records from XPATH
# argument: xpath context
# returns: number of records
# -----

sub get_recordNumbers {

    my $xpathcontext = shift;
    my $numberofrecords;

    if ($xpathcontext->exists('/zs:searchRetrieveResponse/zs:numberOfRecords') ) {
        $numberofrecords = $xpathcontext->findvalue( '/zs:searchRetrieveResponse/zs:numberOfRecords');
    } else {
        print "xpc path not found! \n";
        $numberofrecords = undef;
    }
    return $numberofrecords;
}

# -----
# get_xpc_nodes() get nodes of records with XPATH,
# argument: xpath context
# returns: array of records
# -----

sub get_xpc_nodes {
    my $xpath = shift;
    my @recordNodes  = $xpath->findnodes('/zs:searchRetrieveResponse/zs:records/zs:record/zs:recordData/rec:record');

    return @recordNodes;
}

# -----
# create xml file for export / re-import, add subjects from original data.
# argument: a record object (libxml), subject codes from original file, subject hash from MAP
# returns: xml string
# -----

sub createMARCXML {
	
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
    my %subject_hash = %$hash_ref; # dereference $hashref to get back the hash
    
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

# ----
# print final statistics in a log file
# arguments: all counters, final timer
# ----

sub printStatistics {
	
	my $found = shift;
	my $notfound = shift;
	my $ignored = shift;
	my $unsafe = shift;
	my $totaldocs = shift;
	my $time = shift;

	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
	my $timestamp = ($year+1900).'_'.($mon+1).'_'.$mday.'_'.$hour.'_'.$min;
	my $logfilename = 'log_'.$timestamp.'.txt';
	
	open my $log, ">:encoding(utf8)", $logfilename    or die "$logfilename: $!";
	
	print $log "Final Statistics: $timestamp\n--------------------------------------------------------\n";
	print $log "RECORDS PROCESSED:     $totaldocs\n";  
	print $log "TIME ELAPSED (sec)     "; printf $log ('%.2f',$time);
	print $log "\n";
	print $log "FOUND:      "; printf $log ('%.2f', $found/($totaldocs/100)); print $log "\% ($found)\n";
	print $log "NOT FOUND:  "; printf $log ('%.2f', $notfound/($totaldocs/100)); print $log "\% ($notfound)\n";
	print $log "IGNORED:    "; printf $log ('%.2f', $ignored/($totaldocs/100)); print $log "\% ($ignored)\n";
	print $log "UNSAFE:     "; printf $log ('%.2f', $unsafe/($totaldocs/100)); print $log "\% ($unsafe)\n"; 
  
	close $log	or die "$logfilename: $!";
	print "\nStatistics: see $logfilename\n";
	
}

# -----
# list_of_journals() lists possible titles that indicate
# journals, yearbooks, legislative texts with difficult match criteria.
# records that match this list should be excempted from dedup.
# -----

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

# ----
# function to build subject table: (c) Felix Leu 2018
# read a map file with all possible subject combinations from iff institute
# and build hash accordingly. 
# Example: $subj_hash{'1 GB'} is 'Finanzrecht'
# ----

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

# ----
# function to remove BOM (Microsoft fileheader for Unicode)
# argument: first value from first line
# returns: value without bom characters
# ----

sub removeBOM {
	my $var = shift;
	# remove BOM ( 
	$var =~ s/\xEF\xBB\xBF//;
	$var =~ s/^\x{FEFF}//;
	$var =~ s/^\x{feff}//;
	$var =~ s/^\N{U+FEFF}//;
	$var =~ s/^\N{ZERO WIDTH NO-BREAK SPACE}//;
	$var =~ s/^\N{BOM}//; 

	return $var;
}

# ----
# function to prepare the export array:
# add a row [22] to the current csv line with the selected export message
# if defined, add row [23] with the best match docnr. 
# add the line to the export array. 
# arguments: csv line, export array reference, result string, bestmatch nr.
# returns: export array
# ----

sub prepare_export {
	my $l = shift;
	my $e_ref = shift;
	my $RESULT = shift;
	my $bestmatch = shift;
	
	my @e = @{ $e_ref };
	print $fh_report Dumper $RESULT;	
	print $fh_report Dumper $bestmatch;
	$l->[22] = "$RESULT";
	if (defined $bestmatch) {
		$l->[23] = $bestmatch
	}
    push @e, $l;
    return @e;
	
}

sub print_hash {
	
	my $hash_ref = shift;
	my $fh = shift;
	my %hash = %{$hash_ref};
	
	foreach my $key (keys %hash) {
        #print "Exists\n"    if exists $hash{$key};
        print $fh "$key: $hash{$key}\n"   if defined $hash{$key};
        #print "True\n"      if $hash{$key};
		}

}





# METADATA DEDUPLICATION FOR IFF RECORDS

## NAME

dedup.pl - Perl script for data deduplication by SRU service

## DESCRIPTION

Usage: dedup.pl \[-c config\] \[-f file\] \[-h\]

Parameters:

\-c    desired SRU / matching configuration (gvi or swissbib)

\-f    input data file (.csv)

\-h    help text

More information on script in Readme on GitHub.

## AVAILABILITY 

This script is shared and documented on GitHub: [https://github.com/kathrin77/iff](https://github.com/kathrin77/iff)

## AUTHOR

Kathrin Heim, July 2019 (kathrin.heim@gmail.com)

## SEE ALSO

XML-Parser: [XML::LibXML](https://metacpan.org/pod/XML::LibXML)

XPath Module: [XML::LibXML::XPathContext](https://metacpan.org/pod/XML::LibXML::XPathContext)

CSV Module: [Text::CSV](https://metacpan.org/pod/Text::CSV)

Timer: [Time::HiRes](https://metacpan.org/pod/Time::HiRes)

Config: [Config::Tiny](https://metacpan.org/pod/Config::Tiny)

Command Line Options: [Getopt::Std](https://metacpan.org/pod/Getopt::Std)

Debugging: [Data::Dumper::Names](https://metacpan.org/pod/Data::Dumper::Names)

# SUBROUTINES

## NORMALISATION ROUTINES

- normalize\_isbn()

    This function normalizes isbn numbers, checks if one or two isbn are present, 
    sets flags and returns the normalized isbn and flags.

    Arguments: 
    $originalIsbn: string with original isbn

    Returns: 
    $n\_isbn1, $n\_isbn2: strings, 
    $flag\_isbn1, $flag\_isbn2: numbers (1 or 0) 

- normalize\_author()

    This function normalizes authors, checks for authorities, sets flags and returns the normalized authors and flags.

    Arguments: 
    $originalAuthor: original author string

    Returns: 
    $normalizedauthor: string, 
    $flag: number (0 or 1)

- check\_addendum()

    This function checks addendum for volume information, sets flags and returns the volume information and flags.

    Arguments: 
    $origAddendum: original addendum string

    Returns: 
    $origAddendum, $vol\_number, $vol\_title: strings, 
    $volume\_flag: number (0 or 1)

- check\_analytica() 

    This function checks if there is source information for an analyticum in the addendum.

    Arguments: 
    $originaladdendum: original addendum string

    Returns: 
    $citation, $src\_title, $src\_author: strings, 
    $analytica\_flag: number (0 or 1)

- normalize\_title()

    This function normalizes the title and returns it.

    Arguments: 
    $originalTitle: original title string

    Returns: 
    $originalTitle: string

- check\_subtitles()

    This function checks rows subtitle, volume1 and volume2 for sensible information, 
    sets flag accordingly and normalizes the strings.

    Arguments: 
    $originalSubtitle, $originalTitVol1, $originalTitVol2: original subtitle strings

    Returns: 
    $stit\_flag, $volume\_flag: numbers (0 or 1), 
    $n\_stit, $volumeTitle1, $volumeTitle2: strings

- normalize\_year()

    This function ensures that the year variable contains four digits and selects the latest year.
    It calculates the year-range for the sru query (one year above and below original value).

    Arguments: 
    $originalYear: string

    Returns: 
    $year\_flag: number (0 or 1), 
    $originalYear, $ym1, $yp1: numbers (d{4})

- check\_ppp() 

    This function checks if pages, publisher and place contain information.
    It also checks if pages contain a range and are therefore analytica.

    Arguments: 
    $originalPages, $originalPublisher, $originalPlace: strings

    Returns: 
    $pagerange\_flag, $pub\_flag, $place\_flag: number (0 or 1), 
    $originalPlace, $originalPublisher: strings

- set\_material\_codes() 

    This function deals with diverse material codes and returns correct type and changes some flags.
    It also disables some search values depending on material code.

    Arguments: 
    $flag\_ref: hash reference to %flag, 
    $material: string, 
    $year: number

    Returns: 
    $type: character (m, a or i), 
    $flag{ana}, $flag{isbn1}, $flag{isbn2}, $flag{year}: number (0 or 1), 
    $material: string

- clean\_search\_params() 

    This function tidies the normalized title/author strings and escapes them for the sru query building.

    Arguments: 
    $flag\_ref, $norm\_ref: hash references (%flag, %norm)

    Returns: 
    $escaped\_isbn, $escaped\_year, $escaped\_title, $escaped\_author, $escaped\_publisher, $escaped\_place: strings

## MATCH ROUTINES

- get\_controlfield() 

    This function checks if a specific MARC controlfield exists and returns its content.

    Arguments: 
    $controlfield\_nr: number (MARC controlfield), 
    $conf: configuration object, 
    $record: object (current record node) , 
    $xpath: object (current xpath context), 

    Returns: 
    $controlfield\_content: string or undef

- hasTag() 

    This function checks if a MARC field (datafield) exists.

    Arguments: 
    $tag: number (MARC datafield), 
    $conf: configuration object, 
    $record: object (current record node) , 
    $xpath: object (current xpath context), 

    Returns: 
    1 or 0 (true or false)

- checkIsbnMatch() 

    This function checks if ISBN numbers match.

    Arguments:
    $record: object (current record node),  
    $xpath: object (current xpath context), 
    $original\_isbn: number (isbn number from original data), 
    $conf: configuration object

    Returns: 
    $matchvalue: number

- getMatchValue() 

    This function compares the content of a MARC field to an original string and returns a match value.

    Arguments:
    $df\_content: number (MARC datafield), 
    $sf\_content: number (MARC subfield), 
    $hash\_ref: hash reference (%norm), 
    $key: string (hash key), 
    $conf: configuration object, 
    $record: object (current record node), 
    $xpath: object (current xpath context), 

    Returns: 
    $matchvalue: number

- checkMaterial() 

    This function checks the LDR field in the MARC record, cuts aut position 07 and compares it to the doctype.

    Arguments:
    $hash\_ref: hash reference (%norm), 
    $type: character, 
    $conf: configuration object, 
    $record: object (current record node),  
    $xpath: object (current xpath context) 

    Returns: 
    $matchvalue: number

- check\_network\_g() 

    This function checks origins of each record in the GVI (= which network is the currently evaluated record coming from?). 
    It gets the MARC field 035 from the record and decides on a network match value based on the configuration.
    It also counts the number of MARC fields 035, based on the assumption that 
    the more networks contributed to this record, the better the quality will be.

    Arguments:
    $conf: configuration object, 
    $record: object (current record node),  
    $xpath: object (current xpath context) 

    Returns: 
    $m035\_counter, $highestvalue: number

    The function also returns two undef values to be compliant with check\_network\_s() (see below).

- check\_network\_s() 

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
    $rec\_nrs, $subtotal, : number, 
    $flag\_ref, $replace\_ref: hash references, 
    $sysno, $callno: strings

    Returns: 
    $m035\_counter, $highestvalue: number, 
    \\@iff2replace: array reference, 
    $case: string

- evaluate\_records() 

    This function deals with all the matching for each record in the result set. 
    It compares the different input values with the according MARC fields/subfields:
    ISBN, Author/Authority, Title, Subtitle, Year, Place, etc.
    The function also eliminates totally unsafe matches.

    Arguments:
    $flag\_ref, $norm\_ref: hash references, 
    $config: configuration object, 
    $rec: object (current record node), 
    $xpc: object (current xpath context) 

    Returns: 
    $total: number, 
    $unsafe: number (1 or 0);

## SERVICE ROUTINES

- get\_vars\_from\_csv() 

    This function reads all rows from the csv file and returns it as separate variables.
    rows a until s contain data that is needed for deduplication.
    rows t, u, v (19-21) are not needed, these values come are mapped from a mapping file.

    Arguments:
    $currLine: CSV object (current csv line)

    Returns: 
    $row\_a ... $row\_s: strings

- print\_rep\_header() 

    This function prints a header for each entry in the debug report.

    Arguments:
    $filehandle, $database: strings, 
    $docnumber: number

- print\_doc\_header() 

    This function prints a header for each document in the result set in the debug report.

    Arguments:
    $filehandle, $database: strings, 
    $docnumber: number

- print\_progress() 

    This function prints a progress bar on the output console: 
    a \* for every CSV line treated, every 100th line, the number and remote progress time is printed.

    Arguments:
    $progressnumber: number

- build\_base\_url() 

    This function builds the base url for the SRU query based on values from 
    a config file.

    Arguments:
    $conf: configuration object

    Return:
    $base\_url: string

- build\_sruquery\_basic() 

    This function builds the first sru search (basic version)
    based on either isbn or title/author or title/publisher combo.
    It gets the response from the Server, loads the XML as DOM object 
    and gets the XPATH context for a libxml dom.
    The function also registers namespaces of xml if GVI is used.

    Arguments:
    $base\_url: string, 
    $conf: configuration object, 
    $flag\_ref, $esc\_ref: hash references (%flag, %esc)

    Return:
    $xpathcontext: xpath object (xpc)

- build\_sruquery\_broad() 

    This function builds the broad sru search using cql.all/anywhere
    based on either title/author or title/publisher  or title/year combo.
    It gets the response from the Server, loads the XML as DOM object 
    and gets the XPATH context for a libxml dom.
    The function also registers namespaces of xml if GVI is used.

    Arguments:
    $base\_url: string, 
    $conf: configuration object, 
    $flag\_ref, $esc\_ref: hash references (%flag, %esc)

    Return:
    $xpathcontext: xpath object (xpc)

- build\_sruquery\_narrow() 

    This function builds the the narrow sru search
    based on either title/author or title/publisher or title/year combo.
    It gets the response from the Server, loads the XML as DOM object 
    and gets the XPATH context for a libxml dom.
    The function also registers namespaces of xml if GVI is used.

    Arguments:
    $base\_url: string, 
    $conf: configuration object, 
    $flag\_ref, $esc\_ref: hash references (%flag, %esc)

    Return:
    $xpathcontext: xpath object (xpc)

- get\_record\_nrs() 

    This function retrieves number of records from XPATH.

    Arguments:
    $xpathcontext: xpath object (xpc), 
    $conf: configuration object

    Return:
    $numberofrecords: number

- get\_xpc\_nodes() 

    This function gets nodes of records with XPATH into an array.

    Arguments:
    $xpath: xpath object (xpc), 
    $conf: configuration object

    Return:
    @recordNodes: array 

- create\_MARCXML() 

    This function creates an xml file for export / re-import and adds subjects from original IFF data, 
    based on the iff\_subject\_table.map. 

    Arguments:
    $record: record object, 
    $hash\_ref: hash reference (%subject\_hash), 
    $code 1, $code2, $code3: strings

    Return:
    XML string

- printStatistics() 

    This function prints final statistics in a log file.

    Arguments:
    $ctr\_ref: hash reference (%ctr), 
    $time: timestamp

- list\_of\_journals() 

    This function lists possible titles that indicate journals, yearbooks, legislative texts with difficult match criteria.
    Records that match this list are blacklisted and excempted from dedup.

    Return: 
    $journaltitles: string

- build\_subject\_table() 

    Function to build subject table: (c) Felix Leu 2018
    Read a map file with all possible subject combinations from IFF institute and build hash accordingly. 
    Example: $subj\_hash{'1 GB'} is 'Finanzrecht'

    Return: 
    %subject\_hash: hash with subject keys and subject strings.

- remove\_bom() 

    Function removes the BOM (Microsoft fileheader for Unicode) from the first value in the first line.

    Argument:
    $var: string 

    Return: 
    $var: string

- prepare\_export() 

    Function prepares the export array:
    add a row \[22\] to the current csv line with the selected export message
    if defined, add row \[23\] with the iff docnr. to be replaced
    if defined, add row \[24\] with the best match docnr. 
    add the line to the export array. 

    Argument:
    $l: CSV object ($line), 
    $e\_ref: array reference, 
    $RESULT: string, 
    $bestmatch: string, 
    $replacenr: string, 

    Return: 
    @e: array (export)

- print\_hash() 

    Function prints a hash for debugging.

    Argument:
    $hash\_ref: hash reference, 
    $fh: filehandle

- print\_help() 

    Function prints a little helptext if script is called without options or with option -h.

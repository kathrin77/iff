package Swissbib;

# Swissbib and SRU variables:

# Swissbib SRU-Service for the complete content of Swissbib:
my $swissbib = 'http://sru.swissbib.ch/sru/search/defaultdb?'; 

# needed queries
my $isbnquery = '+dc.identifier+%3D+';
my $titlequery = '+dc.title+%3D+';
my $authorquery = '+dc.creator+%3D+';
my $yearquery = '+dc.date+%3D+';
my $anyquery = '+dc.anywhere+%3D+';

#my $operation = '&operation=searchRetrieve';
#my $schema = '&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light'; # MARC XML - swissbib (less namespaces)
#my $max = '&maximumRecords=10'; # swissbib default is 10 records
#my $query = '&query=';
my $parameters = '&operation=searchRetrieve&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light&maximumRecords=10&query=';

my $server_endpoint;
my $sruquery;

1;
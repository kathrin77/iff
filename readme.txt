There are 2 versions of the script. 
v1_notnormalised (old version, kept for comparison)
v2_normalised (recommended version)

This readme is for the recommended Version v2_normalised.
The v2_normalised Version works with normalized data input and delivers much better results.

Prerequisites:
You need to have perl and libxml2 installed to run this. 
Developed with Strawberry Perl v5.28.1 (LibXML is included).
For Strawberry Perl (Windows):
To include Path to .\Code in @INC (Windows) see:
https://perlmaven.com/how-to-change-inc-to-find-perl-modules-in-non-standard-locations

How to use the script:
Open the script with an editor and choose the data file that you want to run it with (line 50ff.)
The script can be called on the command line like this:
cd v2_normalised
perl sru-swissbib.pl
No parameters are needed.
There is no help function (see this readme file for instructions).
For use of the old version v1_notnormalised/iff_swissbib.pl, there is a separate readme in the directory v1_notnormalised.

The script calls the Swissbib SRU service for each document in the input file, so you will need an active internet connection.
Performance depends on internet connection as well as availability of SRU service.


Input:
uncomment the testfile that you want to try with: 
line 50 ff.
Testfiles and full metadata are in directory /data
Notice: Full data will take about 20 - 30 Minutes!

Output: 
Console output will show a progress bar and give you some statistics at the end. 

Output files:

1) export.csv
It contains all documents (equal to input file) 
Additional mapping info can be found in following columns:
- w: what to do with the documents. Cases:
	- bestcase: already matched correctly
	- leave: no replacement found
	- replacefromSwissbib: replace col. x with col. y, data: see metadata.xml
	- reimportFromSwissbib: replace col. x with col. y, data: see metadata.xml
	- HSB01duplicate: replace col. x with col. y
	- iff_doc_missing: original not found, could be replaced manually with docnr. from col. y
	- notfound: no result from SRU query, do manually
	- unsure: no certain result (match value too low), do manually
	- journal: excluded from matching, do manually


- x: docnr. of document to be replaced (bibnr. in HSB01)
- y: docnr. of replacement document (bibnr. if HSB01 duplicate, swissbibnr. if replacement from swissbib)
- z ff.: additional info for item update (eg. volume information)


2) metadata.xml
MARCXML-Export for cases reimportFromSwissbib and replacefromSwissbib. Swissbibnr. can be found in controlfield 001


3) report.txt
Contains debugging info (quite chatty) for each document, its result set and matching values.




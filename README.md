## Metadata deduplication via SRU search

# Description

Perl Script for data deduplication with SRU service of swissbib or GVI. 
The deduplication process is specially adapted to data from IFF institute of the university of St. Gallen

# Versions

There are several versions of this script.
The recommended version is v4_combined/dedup.pl. This Readme is for the recommended version.
Older versions can be found in directory old_versions, there is a separate readme for versions 1 and 2.


# Prerequisites

You need to have perl and libxml2 installed to run this. 

Developed with Strawberry Perl v5.28.1 (LibXML is included).
For Strawberry Perl (Windows): 
include path to .\iff in @INC [see here](https://perlmaven.com/how-to-change-inc-to-find-perl-modules-in-non-standard-locations)

An image for Ubuntu (VM) with all necessary modules installed can be downloaded here:
[switch drive](https://drive.switch.ch/index.php/s/Tub2XFQLxU3NIXY).

Please read the installation notes.

# Usage

The script calls a SRU service for each document in the input file, so you will need an active internet connection.
Performance depends on internet connection as well as availability of SRU service.
Call the script like this:
```
perl dedup.pl -c [swissbib|gvi] -f [filename]
```

For more information about the script, see the [POD documentation for dedup.pl](v4_combined/dedup_pod.md)

## Parameters

###### SRU Service
You can choose between swissbib or GVI SRU interface. 
- There is a .conf file for each of these SRU interfaces.
- You choose the service with command line parameter -c gvi or -c swissbib.
- Currently, there are no other SRU interfaces implemented. 
- To implement another SRU interface, the new interface needs its own .conf file.
The dedup.pl script would also need to be adapted slightly when getting the options from command line.

###### Input file
You can feed this script with an input file of your choice. It needs to be in csv format. 
- Several testfiles and the full metadata file for the IFF library catalogue are in subdirectory ./data.
- Warning: IFF_Katalog_FULL_normalized will take about 20 - 30 minutes, depending on network. Try a smaller file first!

The data needs to be arranged in rows like the example files in subdirectory ./data, otherwise this script will not work.
Data needs to be in the following rows (rows may be empty unless stated otherwise):
1: author1
2: author2
3: author3
4: title (mandatory)
5: subtitle
6: vol-info1
7: vol-info2
8: isbn
9: pages
10: material type (possible values: Druckerzeugnis, CD-ROM/DVD, Loseblattwerk, Online-Publikation, Zeitung)
11: addendum
12: library or collection
13: call no.
14: place of publication
15: publisher
16: year
17: code1 (refers to a subject table, see [map](v4_combined/iff_subject_table.map))
18: code2 (refers to a subject table, see [map](v4_combined/iff_subject_table.map))
19: code3 (refers to a subject table, see [map](v4_combined/iff_subject_table.map))
20: subj1 (see above)
21: subj2 (see above)
23: subj3 (see above)
rows 24ff. need to be empty.


## Output

Console output will show a progress bar and give you the logfile name at the end. 
The script creates the following output:

- an export file with the original data and the document numbers that need to be replaced and/or imported: export.csv
- an xml file with the exported metadata, which via MARC field 001: metadata.xml
- a report with debugging info: report.txt
- a logfile: log_<timestamp>.txt

###### 1) export.csv
It contains all documents (equal to input file) 
Additional mapping info can be found in following columns:
- w: what to do with the documents. Cases:
	- bestcase: already matched correctly
	- iffonly: only original iff found
	- replace: replace col. x with col. y, data: see metadata.xml
	- reimport: replace col. x with col. y, data: see metadata.xml
	- iffnotfound: original not found, could be replaced manually with docnr. from col. y
	- notfound: no result 
	- unsure: no certain result
	- ignore: excluded from deduplication

- x: docnr. of document to be replaced (swissbib only: system number)
- y: docnr. of replacement document (system number from swissbib or gvi: MARC field 001)


###### 2) metadata.xml
MARCXML-Export for cases reimport and replace. Docnr. can be found in controlfield 001 and corresponds to the export file .


###### 3) report.txt
Contains debugging info (quite chatty) for each document, its result set and matching values.

###### 4) log_<timestamp>.txt
Logfile with statistics
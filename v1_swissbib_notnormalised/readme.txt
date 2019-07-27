Input:
uncomment the testfile that you want to try with: 
line 50 ff.

Output:
Not found / unsure / found replacement, but not original IFF document: notfound.csv
May be done manually. See colon V for a good Swissbib replacement, if something was found. 

Journals, Yearbooks, other special titles to be done manually: journals.csv


To replace from Swissbib: export.csv
Mapping: 
- Old bibnr. (to be replaced in HSB01) see colon U
- Swissbib nr. (to replace above. Nr. can be found in controlfield 001 in metadata.xml) 

To replace from HSB01: hsg_duplicates.csv
- Old bibnr. (to be deleted in HSB01) see colon U
- New bibnr. (to be attached in HSB01) see colon V


---------------------------------------------------------------------------------------
Found documents without any action needed: 
Already matched / Records cannot be improved: see report.txt and console output.

-----------------------------------

For Strawberry Perl (Windows)
To include Path to .\Code in @INC (Windows) see:
https://perlmaven.com/how-to-change-inc-to-find-perl-modules-in-non-standard-locations
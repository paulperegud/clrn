clrn(1)

# NAME

clrn - batch rename files and edit directory tree, using your editor of choice.

# SYNOPSIS

clrn [-h] [-e <EDITOR>] <DIRECTORY>

# DESCRIPTION

clrn is somewhat similar to qmv from moreutils, but takes the idea one step further, allowing to edit (and create) directories as a part of the edit.
If destination path is on other mount point, file will be copied instead of moved.

# OPTIONS

*-h*, *--help* 
	Print this message and exit.
*-e*, -*-editor <EDITOR>*    
	Use EDITOR instead of default editor.   
*<DIRECTORY>*               
	Directory name or `-` for stdin

# AUTHORS

Written and maintained by Paul Peregud <paulperegud@gmail.com>.	

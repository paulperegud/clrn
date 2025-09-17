# clrn

Edit directory tree, using your editor of choice.

This tool is somewhat similar to qmv from moreutils, but takes the idea one step further, allowing to edit (and create) directories as a part of the edit.

## Installation

`clrn` is written in Zig. To compile from source, you will need zig 0.15.1. To install for the local user (assuming `$HOME/.local/bin` is in `$PATH`), run:

```sh
zig build install --release=small --prefix $HOME/.local  
```

which will install `clrn`.

Alternatively, you can use included nix flake.

## Usage

```sh
$ clrn --help
Usage:  clrn [-h] [-e <EDITOR>] <DIRECTORY>
Rename files and edit directory tree using $EDITOR.

    -h, --help
            Print this message and exit.
    -e, --editor <EDITOR>
            Use EDITOR instead of default editor.
    <DIRECTORY>
            Directory name or `-` for stdin
```

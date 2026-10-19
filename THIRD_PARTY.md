# Third-party assets

## Color emoji font (not bundled)

Linux and the browser draw color emoji from a CBLC/CBDT bitmap font.
The font is large, so the repo does not include it. For the browser
build, `minc wasm` downloads Noto Color Emoji with curl on the first
build, caches it under `build/` and copies it into the page. To skip
the download, copy `NotoColorEmoji.ttf` into `assets/` (the file is
gitignored). On Linux, a system-wide Noto Color Emoji also works. Noto
Color Emoji (https://github.com/googlefonts/noto-emoji) is licensed
under the SIL Open Font License 1.1. Windows uses the system font
Segoe UI Emoji. Without a color emoji font, emoji show as empty boxes.

## assets/codicon.ttf

The Codicons icon font, from microsoft/vscode-codicons
(https://github.com/microsoft/vscode-codicons), version 0.0.36.
Licensed under Creative Commons Attribution 4.0 International
(CC BY 4.0, https://creativecommons.org/licenses/by/4.0/).
(c) Microsoft Corporation. Modified: the glyph bounding boxes are
recalculated from the contours. The upstream file stores zero for
xMin and yMin, which breaks text APIs that read the bounds.

## assets/seti.ttf

The Seti file-icon font, converted from seti.woff in
microsoft/vscode (extensions/theme-seti), which packages the Seti UI
theme by Jesse Weed. Both are MIT licensed
(https://github.com/microsoft/vscode/blob/main/LICENSE.txt,
https://github.com/jesseweed/seti-ui/blob/master/LICENSE). Converted
to TrueType, with the glyph bounding boxes recalculated from the
contours for the same reason as codicon.ttf. Otherwise unmodified.

## Built-in color themes (lib/theme.mc)

The color values of the built-in themes are copied from the theme
files below into one table per theme. A few are derived rather than
copied: a translucent background is blended over the editor
background, and the current line's band, the diff view's empty side
and its rule lines are mixed from the theme's background and text. A
color a theme leaves out takes the default microsoft/vscode registers
for it. All are MIT licensed. The tables are adapted from the
original themes and hold fewer colors than they do. edminc is not
affiliated with or endorsed by their authors.

- Dark+, Dark Modern, Light+, Light Modern, Abyss, Kimbie Dark,
  Monokai, Monokai Dimmed, Quiet Light, Red, Solarized Dark, Solarized
  Light and Tomorrow Night Blue: microsoft/vscode
  (https://github.com/microsoft/vscode), the theme-* folders in
  extensions/. (c) Microsoft Corporation
  (https://github.com/microsoft/vscode/blob/main/LICENSE.txt).
- Ayu Dark, Ayu Light, Ayu Mirage: ayu-theme/vscode-ayu
  (https://github.com/ayu-theme/vscode-ayu). (c) 2016 Ike Kurghinyan.
- Cobalt2: wesbos/cobalt2-vscode
  (https://github.com/wesbos/cobalt2-vscode). (c) 2018 Wes Bos,
  Roberto Achar.
- Dracula: dracula/visual-studio-code
  (https://github.com/dracula/visual-studio-code), from src/dracula.yml.
  (c) 2016 Dracula Theme.
- Night Owl, Night Owl Light: sdras/night-owl-vscode-theme
  (https://github.com/sdras/night-owl-vscode-theme). (c) 2018 Sarah
  Drasner.
- Nord: nordtheme/visual-studio-code
  (https://github.com/nordtheme/visual-studio-code). (c) 2016-present
  Sven Greb.
- One Dark Pro: Binaryify/OneDark-Pro
  (https://github.com/Binaryify/OneDark-Pro). (c) 2013-2022 Binaryify.
- Tokyo Night, Tokyo Night Light: enkia/tokyo-night-vscode-theme
  (https://github.com/enkia/tokyo-night-vscode-theme). (c) 2018-present
  Enkia.

## lib/stb_truetype.mc

stb_truetype.h v1.26 by Sean Barrett (https://github.com/nothings/stb),
dual licensed public domain (Unlicense) and MIT. It is transpiled from
the C source to minc. The algorithms and the file format handling are
unmodified. It is the font rasterizer on Linux and in the browser, so
the editor needs neither FreeType nor fontconfig (see doc/TECH_DOC.md
"Dependency policy").

## assets/DejaVuSansMono.ttf, assets/DejaVuSans.ttf

The DejaVu fonts, version 2.37 (https://dejavu-fonts.github.io/). The
browser build uses them as its text and UI faces, since a browser
exposes no system fonts. The Linux build uses the same faces when the
system has them. Unmodified. The license requires this copy of its
text:

```
Fonts are (c) Bitstream (see below). DejaVu changes are in public domain.
Glyphs imported from Arev fonts are (c) Tavmjong Bah (see below)


Bitstream Vera Fonts Copyright
------------------------------

Copyright (c) 2003 by Bitstream, Inc. All Rights Reserved. Bitstream Vera is
a trademark of Bitstream, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of the fonts accompanying this license ("Fonts") and associated
documentation files (the "Font Software"), to reproduce and distribute the
Font Software, including without limitation the rights to use, copy, merge,
publish, distribute, and/or sell copies of the Font Software, and to permit
persons to whom the Font Software is furnished to do so, subject to the
following conditions:

The above copyright and trademark notices and this permission notice shall
be included in all copies of one or more of the Font Software typefaces.

The Font Software may be modified, altered, or added to, and in particular
the designs of glyphs or characters in the Fonts may be modified and
additional glyphs or characters may be added to the Fonts, only if the fonts
are renamed to names not containing either the words "Bitstream" or the word
"Vera".

This License becomes null and void to the extent applicable to Fonts or Font
Software that has been modified and is distributed under the "Bitstream
Vera" names.

The Font Software may be sold as part of a larger software package but no
copy of one or more of the Font Software typefaces may be sold by itself.

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL BITSTREAM OR THE GNOME
FOUNDATION BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING
ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE
FONT SOFTWARE.

Except as contained in this notice, the names of Gnome, the Gnome
Foundation, and Bitstream Inc., shall not be used in advertising or
otherwise to promote the sale, use or other dealings in this Font Software
without prior written authorization from the Gnome Foundation or Bitstream
Inc., respectively. For further information, contact: fonts at gnome dot
org.

Arev Fonts Copyright
------------------------------

Copyright (c) 2006 by Tavmjong Bah. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining
a copy of the fonts accompanying this license ("Fonts") and
associated documentation files (the "Font Software"), to reproduce
and distribute the modifications to the Bitstream Vera Font Software,
including without limitation the rights to use, copy, merge, publish,
distribute, and/or sell copies of the Font Software, and to permit
persons to whom the Font Software is furnished to do so, subject to
the following conditions:

The above copyright and trademark notices and this permission notice
shall be included in all copies of one or more of the Font Software
typefaces.

The Font Software may be modified, altered, or added to, and in
particular the designs of glyphs or characters in the Fonts may be
modified and additional glyphs or characters may be added to the
Fonts, only if the fonts are renamed to names not containing either
the words "Tavmjong Bah" or the word "Arev".

This License becomes null and void to the extent applicable to Fonts
or Font Software that has been modified and is distributed under the 
"Tavmjong Bah Arev" names.

The Font Software may be sold as part of a larger software package but
no copy of one or more of the Font Software typefaces may be sold by
itself.

THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL
TAVMJONG BAH BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.

Except as contained in this notice, the name of Tavmjong Bah shall not
be used in advertising or otherwise to promote the sale, use or other
dealings in this Font Software without prior written authorization
from Tavmjong Bah. For further information, contact: tavmjong @ free
. fr.

TeX Gyre DJV Math
-----------------
Fonts are (c) Bitstream (see below). DejaVu changes are in public domain.

Math extensions done by B. Jackowski, P. Strzelczyk and P. Pianowski
(on behalf of TeX users groups) are in public domain.

Letters imported from Euler Fraktur from AMSfonts are (c) American
Mathematical Society (see below).
Bitstream Vera Fonts Copyright
Copyright (c) 2003 by Bitstream, Inc. All Rights Reserved. Bitstream Vera
is a trademark of Bitstream, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of the fonts accompanying this license (“Fonts”) and associated
documentation
files (the “Font Software”), to reproduce and distribute the Font Software,
including without limitation the rights to use, copy, merge, publish,
distribute,
and/or sell copies of the Font Software, and to permit persons  to whom
the Font Software is furnished to do so, subject to the following
conditions:

The above copyright and trademark notices and this permission notice
shall be
included in all copies of one or more of the Font Software typefaces.

The Font Software may be modified, altered, or added to, and in particular
the designs of glyphs or characters in the Fonts may be modified and
additional
glyphs or characters may be added to the Fonts, only if the fonts are
renamed
to names not containing either the words “Bitstream” or the word “Vera”.

This License becomes null and void to the extent applicable to Fonts or
Font Software
that has been modified and is distributed under the “Bitstream Vera”
names.

The Font Software may be sold as part of a larger software package but
no copy
of one or more of the Font Software typefaces may be sold by itself.

THE FONT SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF COPYRIGHT, PATENT,
TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL BITSTREAM OR THE GNOME
FOUNDATION
BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, INCLUDING ANY GENERAL,
SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, WHETHER IN AN
ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF THE USE OR
INABILITY TO USE
THE FONT SOFTWARE OR FROM OTHER DEALINGS IN THE FONT SOFTWARE.
Except as contained in this notice, the names of GNOME, the GNOME
Foundation,
and Bitstream Inc., shall not be used in advertising or otherwise to promote
the sale, use or other dealings in this Font Software without prior written
authorization from the GNOME Foundation or Bitstream Inc., respectively.
For further information, contact: fonts at gnome dot org.

AMSFonts (v. 2.2) copyright

The PostScript Type 1 implementation of the AMSFonts produced by and
previously distributed by Blue Sky Research and Y&Y, Inc. are now freely
available for general use. This has been accomplished through the
cooperation
of a consortium of scientific publishers with Blue Sky Research and Y&Y.
Members of this consortium include:

Elsevier Science IBM Corporation Society for Industrial and Applied
Mathematics (SIAM) Springer-Verlag American Mathematical Society (AMS)

In order to assure the authenticity of these fonts, copyright will be
held by
the American Mathematical Society. This is not meant to restrict in any way
the legitimate use of the fonts, such as (but not limited to) electronic
distribution of documents containing these fonts, inclusion of these fonts
into other public domain or commercial font collections or computer
applications, use of the outline data to create derivative fonts and/or
faces, etc. However, the AMS does require that the AMS copyright notice be
removed from any derivative versions of the fonts which have been altered in
any way. In addition, to ensure the fidelity of TeX documents using Computer
Modern fonts, Professor Donald Knuth, creator of the Computer Modern faces,
has requested that any alterations which yield different font metrics be
given a different name.

$Id$
```

"""Compile documents and rasterize PDF pages for retained terminal images."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.parse


HTML_PREVIEW_CSS = r'''
@page {
    size: A4 portrait;
    margin: 10mm;
}

html,
body {
    box-sizing: border-box;
    width: auto !important;
    min-width: 0 !important;
    max-width: 100% !important;
}

body {
    margin: 0 !important;
    overflow-wrap: anywhere;
}

body > *,
table,
tbody,
thead,
tfoot,
tr,
th,
td {
    box-sizing: border-box;
    min-width: 0 !important;
    max-width: 100% !important;
}

table {
    width: 100% !important;
    table-layout: auto !important;
}

table[width],
th[width],
td[width] {
    width: auto !important;
}

th,
td {
    overflow-wrap: anywhere;
    word-break: normal;
}

img,
svg,
video,
canvas,
iframe {
    max-width: 100% !important;
    height: auto !important;
}

pre,
code {
    white-space: pre-wrap !important;
    overflow-wrap: anywhere;
}
'''


def install_cisxxx_fallback(directory):
    """Provide a preview-only substitute for the missing UPenn template class."""
    (directory / 'cisXXX.cls').write_text(
        r'''\NeedsTeXFormat{LaTeX2e}
\ProvidesClass{cisXXX}[2026/09/24 edocview preview compatibility]
\LoadClass[11pt]{article}
\RequirePackage[margin=1in]{geometry}
\RequirePackage{amsmath,amssymb}
\newcommand{\edocviewHWauthor}{}
\newcommand{\edocviewHWemail}{}
\newcommand{\edocviewHWnumber}{}
\newcommand{\edocviewHWcourse}{CIS}
\newcommand{\edocviewHWpartners}{}
\newcommand{\HWauthor}[2]{\renewcommand{\edocviewHWauthor}{#1}\renewcommand{\edocviewHWemail}{#2}}
\newcommand{\HWno}[1]{\renewcommand{\edocviewHWnumber}{#1}}
\newcommand{\HWcourse}[1]{\renewcommand{\edocviewHWcourse}{#1}}
\newcommand{\HWpartner}[1]{\g@addto@macro\edocviewHWpartners{#1\\}}
\newcommand{\HWextension}{}
\newcounter{edocviewproblem}
\newcounter{edocviewsubproblem}[edocviewproblem]
\newcommand{\HWproblem}{%
  \stepcounter{edocviewproblem}%
  \setcounter{edocviewsubproblem}{0}%
  \section*{Problem \theedocviewproblem}}
\newcommand{\HWsubproblem}{%
  \stepcounter{edocviewsubproblem}%
  \subsection*{\alph{edocviewsubproblem})}}
\renewcommand{\maketitle}{%
  \begin{center}
    {\Large\bfseries
      \edocviewHWcourse{} Homework \edocviewHWnumber\par}
    \vspace{0.5em}
    \edocviewHWauthor{} \texttt{\edocviewHWemail}\par
    \edocviewHWpartners
  \end{center}\vspace{1em}}
'''
    )


def run(command, cwd, env=None, stdin=None):
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        input=stdin,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(result.stdout[-1500:] + '\n' + result.stderr[-2500:])


def concise_error(error):
    """Extract one useful compiler diagnostic instead of dumping its log."""
    text = str(error)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    missing_class = re.search(r"LaTeX Error: File [`']([^`']+\.cls)' not found", text)
    if missing_class:
        name = missing_class.group(1)
        return f'Missing custom LaTeX class {name}. Put it beside the source file or change \\documentclass.'
    for line in lines:
        if line.startswith('! LaTeX Error:'):
            return line[2:][:800]
    for index, line in enumerate(lines):
        if re.search(r'\.tex:\d+:', line):
            return ' '.join(lines[index:index + 3])[:800]
    for line in lines:
        if line.startswith('! '):
            return line[2:][:800]
    for line in lines:
        if line.lower().startswith(('error:', 'fatal:')):
            return line[:800]
    return (lines[-1] if lines else 'document compiler failed')[:800]


def latex_command(source):
    return [
        'latexmk',
        '-xelatex',
        '-interaction=nonstopmode',
        '-halt-on-error',
        '-file-line-error',
        '-output-directory=' + str(source.parent),
        str(source),
    ]


def latex_body_is_empty(contents):
    body = contents
    if r'\begin{document}' in body:
        body = body.split(r'\begin{document}', 1)[1]
    if r'\end{document}' in body:
        body = body.split(r'\end{document}', 1)[0]
    body = re.sub(r'(?<!\\)%.*', '', body)
    return not body.strip()


def compile_document(source, target, original):
    source = pathlib.Path(source).resolve()
    target = pathlib.Path(target).resolve()
    original = pathlib.Path(original).resolve()
    kind = source.suffix.lower()
    if kind in ('.md', '.markdown'):
        typst_command = [
            'pandoc',
            str(source),
            '--from=gfm+tex_math_dollars',
            '--resource-path=' + str(original),
            '--pdf-engine=typst',
            '-V',
            'mainfont=Libertinus Serif',
            '-o',
            str(target),
        ]
        try:
            run(typst_command, original)
        except RuntimeError as error:
            # Some minimal systems expose no fonts to Typst. Preserve a
            # reliable XeLaTeX fallback without slowing the normal fast path.
            if 'font fallback list must not be empty' not in str(error):
                raise
            run(
                [
                    'pandoc',
                    str(source),
                    '--from=gfm+tex_math_dollars',
                    '--resource-path=' + str(original),
                    '--pdf-engine=xelatex',
                    '-o',
                    str(target),
                ],
                original,
            )
    elif kind == '.typ':
        # Stdin preserves unsaved text while --root keeps relative resources
        # anchored to the real document directory rather than the cache.
        run(
            ['typst', 'compile', '--root', str(original), '-', str(target)],
            original,
            stdin=source.read_text(),
        )
    elif kind in ('.html', '.htm'):
        from weasyprint import CSS, HTML, default_url_fetcher

        def local_url_fetcher(url):
            """Keep editor previews deterministic and independent of the network."""
            scheme = urllib.parse.urlparse(url).scheme.lower()
            if scheme not in ('', 'file', 'data'):
                raise ValueError(f'remote HTML resource disabled: {url}')
            return default_url_fetcher(url, timeout=2)

        # base_url keeps relative stylesheets, fonts, and images anchored to
        # the real document even though unsaved buffer text lives in a cache.
        HTML(
            string=source.read_text(),
            base_url=str(original),
            url_fetcher=local_url_fetcher,
        ).write_pdf(target, stylesheets=[CSS(string=HTML_PREVIEW_CSS)])
    elif kind == '.tex':
        env = dict(os.environ)
        contents = source.read_text()
        document_class = re.search(
            r'\\documentclass(?:\[[^]]*\])?\{([^}]+)\}', contents
        )
        if (
            document_class
            and document_class.group(1) == 'cisXXX'
            and not (original / 'cisXXX.cls').exists()
        ):
            install_cisxxx_fallback(source.parent)
        env['TEXINPUTS'] = (
            str(source.parent)
            + '//'
            + os.pathsep
            + str(original)
            + '//'
            + os.pathsep
            + env.get('TEXINPUTS', '')
        )
        compile_source = source
        if r'\documentclass' not in contents:
            compile_source = source.parent / 'edocview-wrapper.tex'
            compile_source.write_text(
                '\\documentclass{article}\n'
                '\\usepackage{amsmath,amssymb}\n'
                '\\usepackage{graphicx}\n'
                '\\begin{document}\n'
                + contents
                + '\n\\end{document}\n'
            )
        if latex_body_is_empty(compile_source.read_text()):
            placeholder = source.parent / 'edocview-placeholder.tex'
            placeholder.write_text(
                compile_source.read_text().replace(
                    r'\begin{document}',
                    r'\begin{document}\mbox{}',
                    1,
                )
            )
            compile_source = placeholder
        try:
            run(latex_command(compile_source), original, env)
        except RuntimeError as error:
            message = str(error)
            if 'No pages of output' not in message and 'no output was made' not in message:
                raise RuntimeError(concise_error(error)) from error
            placeholder = source.parent / 'edocview-placeholder.tex'
            placeholder.write_text(
                compile_source.read_text().replace(
                    r'\begin{document}',
                    r'\begin{document}\mbox{}',
                    1,
                )
            )
            run(latex_command(placeholder), original, env)
            compile_source = placeholder
        (source.parent / (compile_source.stem + '.pdf')).replace(target)
    else:
        raise ValueError('unsupported format: ' + kind)


def pages(pdf, output_dir, width):
    """Rasterize each page once for retained Kitty image placements."""
    import fitz

    doc = fitz.open(pdf)
    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    width = int(width)
    rendered = []
    try:
        if not doc.page_count:
            raise ValueError('empty PDF')
        for index, page in enumerate(doc):
            zoom = width / page.rect.width
            pixmap = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
            path = (output_dir / f'page-{index + 1:04d}.png').resolve()
            pixmap.save(path)
            rendered.append({
                'path': str(path),
                'hash': hashlib.sha256(pixmap.samples).hexdigest(),
                'width': pixmap.width,
                'height': pixmap.height,
            })
    finally:
        doc.close()
    print(json.dumps(rendered))


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'compile':
            compile_document(*sys.argv[2:5])
        elif sys.argv[1] == 'pages':
            pages(*sys.argv[2:5])
        else:
            raise ValueError('expected compile or pages')
    except Exception as error:
        print(concise_error(error), file=sys.stderr)
        sys.exit(1)

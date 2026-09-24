"""Compile documents and rasterize the visible part of a multipage PDF."""
import os
import pathlib
import subprocess
import sys

import fitz
from PIL import Image


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


def compile_document(source, target, original):
    source = pathlib.Path(source).resolve()
    target = pathlib.Path(target).resolve()
    original = pathlib.Path(original).resolve()
    kind = source.suffix.lower()
    if kind in ('.md', '.markdown'):
        run(['pandoc', str(source), '--from=gfm+tex_math_dollars',
             '--resource-path=' + str(original), '--pdf-engine=xelatex', '-o', str(target)], original)
    elif kind == '.typ':
        # Stdin preserves unsaved text while --root keeps relative resources
        # anchored to the real document directory rather than the cache.
        run(
            ['typst', 'compile', '--root', str(original), '-', str(target)],
            original,
            stdin=source.read_text(),
        )
    elif kind == '.tex':
        env = dict(os.environ)
        env['TEXINPUTS'] = str(original) + os.pathsep + env.get('TEXINPUTS', '')
        run(['latexmk', '-pdf', '-interaction=nonstopmode', '-halt-on-error',
             '-output-directory=' + str(source.parent), str(source)], original, env)
        (source.parent / (source.stem + '.pdf')).replace(target)
    else:
        raise ValueError('unsupported format: ' + kind)


def viewport(pdf, output, width, height, fraction):
    doc = fitz.open(pdf)
    try:
        if not doc.page_count:
            raise ValueError('empty PDF')
        width, height = int(width), int(height)
        fraction = max(0.0, min(1.0, float(fraction)))
        dimensions = [(page.rect.width, page.rect.height) for page in doc]
        heights = [round(h * width / w) for w, h in dimensions]
        gap = max(8, round(width * .015))
        whole = sum(heights) + gap * (len(heights) - 1)
        offset = round(fraction * max(0, whole - height))
        canvas = Image.new('RGB', (width, height), 'white')
        top = 0
        for index, ((page_width, _), page_height) in enumerate(zip(dimensions, heights)):
            if top + page_height > offset and top < offset + height:
                zoom = width / page_width
                pix = doc[index].get_pixmap(matrix=fitz.Matrix(zoom, zoom), alpha=False)
                page = Image.frombytes('RGB', (pix.width, pix.height), pix.samples)
                canvas.paste(page, (0, top - offset))
            top += page_height + gap
        canvas.save(output)
    finally:
        doc.close()


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'compile':
            compile_document(*sys.argv[2:5])
        elif sys.argv[1] == 'viewport':
            viewport(*sys.argv[2:7])
        else:
            raise ValueError('expected compile or viewport')
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)

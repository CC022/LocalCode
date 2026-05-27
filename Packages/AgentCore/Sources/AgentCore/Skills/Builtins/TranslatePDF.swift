import Foundation

extension Skill {
    /// Recipe for "translate a PDF": parse to Markdown first, then run the
    /// chunked translator on the produced Markdown. Pulled in when the user
    /// asks to translate a paper / handout / book in PDF form.
    static let translatePDF = Skill(
        name: "translate-pdf",
        description: "How to translate a long PDF: parse to Markdown, then translate the Markdown.",
        body: """
        # translate-pdf

        PDFs don't translate directly — there's no native LaTeX/structure
        recovery once a doc is rasterized to glyphs. The workflow is:

        ## 1. Parse the PDF

        Call `parse_pdf` on the input file. It writes
        `<basename>.parsed/document.md` plus an `images/` directory of
        extracted figure PNGs. The agent reads chunks of that markdown via
        `read_file` if it needs to inspect content.

        ## 2. Translate the Markdown

        Call `translate_md` on the produced markdown:

        ```
        translate_md(
          path: "<basename>.parsed/document.md",
          target_language: "Chinese (Simplified)"   // or Japanese, Spanish, etc.
        )
        ```

        Defaults are good for most cases. Output lands at
        `<basename>.parsed/document.<lang-code>.md` next to the source.
        Image placeholders and `## Page N` headers pass through unchanged,
        so the translated file remains aligned with the figures.

        ## 3. Surface the result

        Tell the user the output path. If `translate_md` reports warnings
        (missing image placeholders / page headers in some chunks), mention
        the count and the `.warnings.txt` location.

        ## Cost & timing

        Long docs run for minutes on the local model — one inference pass
        per chunk, no real-time progress UI. The tool returns once with a
        summary. Set a smaller `chunk_chars` (e.g. 3000) if the model
        struggles with long contexts.

        ## Don't

        - Don't try to "translate the PDF directly" — there's no such tool;
          PDFs must be parsed to Markdown first.
        - Don't ask the model to translate the markdown by reading and
          paraphrasing it inline; that loses structure and image
          placeholders. Always use `translate_md`.
        """
    )
}

// Bear thumbnail resize — BetterTouchTool JS action.
// Paste this into the BTT action body that's bound to ⌥R (width=150) or ⇧⌥R (width=300).
//
// Two bugs fixed from the previous version:
//
// 1. Removed `imgAdd` entirely. `imgChange` already handles both "no existing comment"
//    and "has width comment" cases (its groups 2 and 3 are optional). Running `imgAdd`
//    after `imgChange` caused every image to end up with a duplicate comment, because
//    `imgAdd`'s `([<]|$)` tail matched the `<` of the comment `imgChange` had just added.
//    Net effect of the old bug: every image had `<!-- {"width":N} --><!-- {"width":N} -->`.
//
// 2. `pdfAdd` replacement changed from `$2` to `$3`. The regex has nested captures —
//    `$2` is the link text (inner group), `$3` is the tail character. The old code used
//    `$2`, so a bare `[doc](foo.pdf)` produced `[doc](foo.pdf)<!-- ... -->doc` (spurious
//    link text appended), and `[doc](foo.pdf) rest` lost the separator and became
//    `[doc](foo.pdf)<!-- ... -->docrest`. Using `$3` preserves whatever character
//    followed the PDF (space, newline, end-of-string).

async (selectionString) => {
    var width = 150; // smallest for ⌥R
                     // 300; // medium for ⇧⌥R

    function resizeThumbnails(text) {
        var // IMG — add/replace the width comment in one pass.
            //   Groups 2 (any trailing comments, zero or more) and 3 (width comment) are both
            //   optional, so this single regex handles: no comment, existing width, existing
            //   non-width comment, and multiple comments. Replacement discards groups 2 and 3
            //   and writes a fresh width comment.
            imgChange = /(!\[\]\([^\)]+\))(<!--.*?-->)*(<!-- \{"width":(\d+)} -->)?/g,

            // PDF — change existing width value when there's already a width key.
            pdfChange = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]*"width":)(\d+)([^\}]*} -->)?/g,

            // PDF — add width key to an existing comment that lacks one.
            pdfChangeAdd = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]+)(} -->)?/g,

            // PDF — add a fresh width comment when none exists. Excludes `<` in link/path/tail
            // so it won't re-fire on a PDF that already has a comment after it.
            pdfAdd = /(\[([^\]<]+)\]\([^\)<]+pdf\))([^<]|$)/g;

        return text
            .replace(imgChange, "$1<!-- {\"width\":" + width + "} -->")
            .replace(pdfChange, "$1$3" + width + "$5")
            .replace(pdfChangeAdd, function (match, pdfLink, _pdfLink, currentComment, endOfCurrentComment) {
                if (!currentComment.match(/width/)) {
                    return pdfLink +
                        currentComment +
                        ", \"width\":" +
                        width +
                        endOfCurrentComment;
                } else { // handled by pdfChange
                    return match;
                }
            })
            .replace(pdfAdd, "$1<!-- {\"width\":" + width + "} -->$3");
    }

    return resizeThumbnails(selectionString);
}

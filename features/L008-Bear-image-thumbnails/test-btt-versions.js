// Compare the ORIGINAL BTT code (with imgAdd and $2-in-pdfAdd bugs) against the
// FIXED version side-by-side to expose regressions. Run with `node test-btt-versions.js`.

const originalFn = async (selectionString) => {
    var width = 150;
    function resizeThumbnails(text) {
        var imgChange = /(!\[\]\([^\)]+\))(<!--.*?-->)*(<!-- \{"width":(\d+)} -->)?/g,
            imgAdd = /(!\[\]\([^\)]+\))([<]|$)/g,
            pdfChange = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]*"width":)(\d+)([^\}]*} -->)?/g,
            pdfChangeAdd = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]+)(} -->)?/g,
            pdfAdd = /(\[([^\]<]+)\]\([^\)<]+pdf\))([^<]|$)/g;
        return text
            .replace(imgChange, "$1<!-- {\"width\":" + width + "} -->")
            .replace(imgAdd, "$1<!-- {\"width\":" + width + "} -->$2")
            .replace(pdfChange, "$1$3" + width + "$5")
            .replace(pdfChangeAdd, function (m, pdfLink, _p, currentComment, endOfCurrentComment) {
                if (!currentComment.match(/width/)) return pdfLink + currentComment + ", \"width\":" + width + endOfCurrentComment;
                return m;
            })
            .replace(pdfAdd, "$1<!-- {\"width\":" + width + "} -->$2");
    }
    return resizeThumbnails(selectionString);
};

const fixedFn = async (selectionString) => {
    var width = 150;
    function resizeThumbnails(text) {
        var imgChange = /(!\[\]\([^\)]+\))(<!--.*?-->)*(<!-- \{"width":(\d+)} -->)?/g,
            pdfChange = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]*"width":)(\d+)([^\}]*} -->)?/g,
            pdfChangeAdd = /(\[([^\]]+)\]\([^\)]+pdf\))(<!-- \{[^\}]+)(} -->)?/g,
            pdfAdd = /(\[([^\]<]+)\]\([^\)<]+pdf\))([^<]|$)/g;
        return text
            .replace(imgChange, "$1<!-- {\"width\":" + width + "} -->")
            .replace(pdfChange, "$1$3" + width + "$5")
            .replace(pdfChangeAdd, function (m, pdfLink, _p, currentComment, endOfCurrentComment) {
                if (!currentComment.match(/width/)) return pdfLink + currentComment + ", \"width\":" + width + endOfCurrentComment;
                return m;
            })
            .replace(pdfAdd, "$1<!-- {\"width\":" + width + "} -->$3");  // <-- $3 not $2
    }
    return resizeThumbnails(selectionString);
};

const cases = [
    "![](x.png)",
    "![](x.png) hello",
    "![](x.png)\n",
    "![](x.png)<!-- {\"width\":300} -->",
    "[doc](foo.pdf)",
    "[doc](foo.pdf)\nnext line",
    "[doc](foo.pdf) and more",
    "[doc](foo.pdf)<!-- {\"page\":1} -->",
    "no media here",
];

(async () => {
    for (const input of cases) {
        const orig = await originalFn(input);
        const fixed = await fixedFn(input);
        const delta = orig === fixed ? "SAME" : "DIFFER";
        console.log("----", delta, "----");
        console.log(" in  :", JSON.stringify(input));
        console.log(" orig:", JSON.stringify(orig));
        console.log(" fix :", JSON.stringify(fixed));
    }
})();

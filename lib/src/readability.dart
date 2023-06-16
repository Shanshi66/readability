import 'dart:collection';
import 'dart:core';
import 'dart:math';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as parser;

import 'config.dart';
import 'cleaner.dart';

class HtmlDocument {
  String input;
  Pattern? positiveKeywords;
  Pattern? negativeKeywords;
  String? url;
  int minTextLength;
  int retryLength;
  late Document _html;

  late String _content;
  late String _title;
  late String _pureHeml;
  late String _author;

  String get title => _title;
  String get content => _content;
  String get author => _author;
  String get pureHtml => _pureHeml;

  HtmlDocument({
    required this.input,
    this.positiveKeywords,
    this.negativeKeywords,
    this.url,
    this.minTextLength = 25,
    this.retryLength = 250,
  });

  /// clean html document, remove script, style, etc.
  void _cleanUnUsefulTag() {
    for (var tag in unUsefulTag) {
      _html.querySelectorAll(tag).forEach((e) => e.remove());
    }
  }

  /// repalce '&lt;' with '<' and '&gt;' with '>'
  String _replaceLtGt(String s) {
    s = s.replaceAll(RegExp(r'&lt;'), '<');
    s = s.replaceAll(RegExp(r'&gt;'), '>');
    return s;
  }

  /// turn Chinese Punctuation marks into English Punctuation marks
  // String _turnChinesePunctuationMarks(String s) {
  //   s = s.replaceAll(RegExp(r'，'), ',');
  //   s = s.replaceAll(RegExp(r'。'), '.');
  //   return s;
  // }

  /// score nodes in html
  Map<Element, double> _scoreParagraphs() {
    Map<Element, double> candidates = HashMap();
    // all element of in textTag
    var allTextTag = _html.querySelectorAll(scoreTag.join(','));
    for (var tag in allTextTag) {
      var parentTag = tag.parent;
      if (parentTag == null) {
        continue;
      }
      var grandParentTag = parentTag.parent;
      //TODO put it into beginning
      String innerText = cleanText(tag.text);
      int innerTextLen = innerText.length;

      // If this paragraph is less than 25 characters, don't even count it.
      if (innerTextLen < minTextLength) {
        continue;
      }

      if (!candidates.containsKey(parentTag)) {
        candidates[parentTag] = _scoreNode(parentTag);
      }

      if (grandParentTag != null && !candidates.containsKey(grandParentTag)) {
        candidates[grandParentTag] = _scoreNode(grandParentTag);
      }

      double score = 1;
      // TODO use config
      score += min(innerTextLen / 100, 3);

      score += innerText.split(RegExp(r'[，,]')).length;

      candidates[parentTag] = candidates[parentTag]! + score;
      if (grandParentTag != null) {
        candidates[grandParentTag] = candidates[grandParentTag]! + score / 2;
      }

      // iterate the candiate, caculate link density
      for (var candidate in candidates.keys) {
        var links = candidate.querySelectorAll('a');
        var text = candidate.text;
        var linkLength = 0;
        for (var link in links) {
          linkLength += link.text.length;
        }
        var linkDensity = linkLength / text.length;
        candidates[candidate] = candidates[candidate]! * (1 - linkDensity);
      }
    }
    return candidates;
  }

  /// score elem
  double _scoreNode(Element elem) {
    double score = 0;
    score += tagScore[elem.localName] ?? 0;
    return score;
  }

  /// replace <div> to <p> if there is no block tag in <div>
  /// traversal the dom tree recursively, if the tag is <div> and all son node dont have block tag, replace it with <p>
  void _replaceDiv() {
    // querySelectorAll return a pre-order traversal of dom tree
    var allDiv = _html.querySelectorAll('div').reversed;
    for (var div in allDiv) {
      var isBlock = false;
      for (var tag in blockTag) {
        if (div.querySelector(tag) != null) {
          isBlock = true;
          break;
        }
      }
      if (!isBlock) {
        Element p = Element.tag('p');
        p.children.addAll(div.children);
        div.replaceWith(p);
      }
    }
  }

  void _getTitle() {
    // first get title from meta
    _title = _html
            .querySelector('meta[property="og:title"]')
            ?.attributes['content'] ??
        '';
    // if title is empty, get title from <title>
    if (_title.isEmpty) {
      _title = _html.querySelector('title')?.text ?? '';
    }
    // if title is empty, get title from <h1>
    if (_title.isEmpty) {
      _title = _html.querySelector('h1')?.text ?? '';
    }
  }

  void _getAuthor() {
    _author =
        _html.querySelector('meta[name="author"]')?.attributes['content'] ??
            "[No Author]";
  }

  /// produce pure html with title, author, content
  void _producePureHtml() {
    // if _content not contain h1, add title to _content
    if (!_content.contains('<h1')) {
      _content = '<h1>$_title</h1>$_content';
    }
    _pureHeml = '''
    <html>
      <body>
        $_content
      </body>
    </html>
    ''';
  }

  /// main process of the article extraction
  bool parse() {
    // input = _turnChinesePunctuationMarks(input);

    _html = parser.parse(input);

    // if _html contains not parse tag, return false
    if (_html.querySelector(notParseTag.join(',')) != null) {
      return false;
    }

    _getTitle();
    _getAuthor();
    _cleanUnUsefulTag();
    _replaceDiv();

    Map<Element, double> candidates = _scoreParagraphs();

    Element? topCandidate = _selectBestCandidate(candidates);

    if (topCandidate != null) {
      _figurePretty(topCandidate);
      _removeEmptyTag(topCandidate);
      _removeUnUsefulAttribue(topCandidate);
      _content = topCandidate.outerHtml;
    } else {
      _content = "[No Content]";
    }
    _producePureHtml();
    return true;
  }

  /// remove all attribute of element except for the attribute in keepAttr
  void _removeUnUsefulAttribue(Element elem) {
    if (attrKeepTag.contains(elem.localName)) {
      return;
    }
    elem.attributes.removeWhere((key, value) => !keepAttr.contains(key));
    for (var child in elem.children) {
      _removeUnUsefulAttribue(child);
    }
  }

  /// if tag in textTag and its text is empty, remove it
  void _removeEmptyTag(Element elem) {
    if (textTag.contains(elem.localName) && elem.text.trim().isEmpty) {
      elem.remove();
      return;
    }
    for (var child in elem.children) {
      _removeEmptyTag(child);
    }
  }

  /// query all figure tag
  /// if there is <noscript> in figure, remove img in figure, and put the img in noscript to figure
  /// this is for the case that the img in figure is from rendered by javascript
  void _figurePretty(Element elem) {
    var figures = elem.querySelectorAll('figure');
    for (var figure in figures) {
      var noscript = figure.querySelector('noscript');
      if (noscript != null) {
        // create a new figure Element, and put the img in noscript to it
        Element newFigure = Element.tag('figure');
        newFigure.innerHtml = _replaceLtGt(noscript.innerHtml);
        figure.replaceWith(newFigure);
      }
    }
  }

  // choose best candidate
  Element? _selectBestCandidate(Map<Element, double> candidates) {
    return candidates.entries
        .reduce(
            (entry1, entry2) => entry1.value > entry2.value ? entry1 : entry2)
        .key;
  }
}

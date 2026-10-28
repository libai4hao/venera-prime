import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';

void main() {
  test('reads common ComicInfo metadata fields', () {
    final metadata = ComicMetaData.fromComicInfoXml('''
      <ComicInfo>
        <Title>Library 10</Title>
        <Writer>Alice</Writer>
        <Summary>A local description</Summary>
      <LanguageISO>ja</LanguageISO>
      <Genre>Drama, Mystery</Genre>
      <Notes>Chapters: Part 1: 1-5; Part 2: 6-10</Notes>
      </ComicInfo>
    ''');
    expect(metadata.title, 'Library 10');
    expect(metadata.language, 'ja');
    expect(metadata.author, 'Alice');
    expect(metadata.description, 'A local description');
    expect(metadata.tags, ['Drama', 'Mystery']);
    expect(metadata.chapters, hasLength(2));
    expect(metadata.chapters!.last.title, 'Part 2');
    expect(metadata.chapters!.last.end, 10);
  });

  test('accepts chapter page aliases from metadata.json', () {
    final metadata = ComicMetaData.fromJson({
      'title': 'Library',
      'language': 'zh-CN',
      'chapters': [
        {'name': 'Bonus', 'startPage': '11', 'endPage': 12},
      ],
    });
    expect(metadata.language, 'zh-CN');
    expect(metadata.chapters, hasLength(1));
    expect(metadata.chapters!.single.title, 'Bonus');
    expect(metadata.chapters!.single.start, 11);
  });
}

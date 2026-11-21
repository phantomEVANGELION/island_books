import 'package:flutter_test/flutter_test.dart';
import 'package:island_books/core/utils/natural_sort.dart';

void main() {
  group('自然排序', () {
    test('卷号按数值排，不是字典序', () {
      final titles = [
        '无职转生 ～到了异世界就拿出真本事～ 10',
        '无职转生 ～到了异世界就拿出真本事～ 2',
        '无职转生 ～到了异世界就拿出真本事～ 1',
        '无职转生 ～到了异世界就拿出真本事～ 11',
        '无职转生 ～到了异世界就拿出真本事～ 3',
      ];
      titles.sort(naturalCompare);
      final nums = titles.map((t) => int.parse(t.split('～').last.trim())).toList();
      expect(nums, [1, 2, 3, 10, 11]);
    });

    test('带前导零也能正确排', () {
      final titles = ['卷10', '卷02', '卷01', '卷03'];
      titles.sort(naturalCompare);
      expect(titles, ['卷01', '卷02', '卷03', '卷10']);
    });

    test('中文书名按字典序', () {
      final titles = ['为美好的世界献上祝福', '无职转生', '素晴'];
      titles.sort(naturalCompare);
      expect(titles.first, '为美好的世界献上祝福');
    });
  });
}

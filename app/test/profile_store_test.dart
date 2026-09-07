// Every mutating method starts from readAll(), so an unmodifiable result
// makes the first save of a fresh install throw and the pairing screen
// silently do nothing.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:remote_omp/profile_store.dart';
import 'package:remote_omp/protocol.dart';

SavedProfile _profile(String id, {String label = 'laptop'}) => SavedProfile(
  id: id,
  label: label,
  url: 'ws://100.64.0.3:8788',
  token: '0123456789abcdef',
  role: ClientRole.control,
  agentId: 'workstation/proj#ab12',
  isDirect: true,
);

Future<ProfileStore> _emptyStore() async {
  SharedPreferences.setMockInitialValues({});
  return ProfileStore(await SharedPreferences.getInstance());
}

void main() {
  test('saves the first profile on a store that has never been written', () async {
    final store = await _emptyStore();
    await store.upsert(_profile('1'));
    expect(store.readAll().map((p) => p.id), ['1']);
  });

  test('removing from an empty store is a no-op rather than a throw', () async {
    final store = await _emptyStore();
    await store.remove('nope');
    expect(store.readAll(), isEmpty);
  });

  test('replaces a profile with the same id instead of appending', () async {
    final store = await _emptyStore();
    await store.upsert(_profile('1', label: 'old'));
    await store.upsert(_profile('1', label: 'new'));
    final all = store.readAll();
    expect(all, hasLength(1));
    expect(all.single.label, 'new');
  });

  test('orders by last use, with never-used profiles last', () async {
    final store = await _emptyStore();
    await store.upsert(_profile('a'));
    await store.upsert(_profile('b'));
    await store.recordUsed('b');
    expect(store.readAll().map((p) => p.id), ['b', 'a']);
  });

  test('survives a corrupt stored payload instead of crashing the list', () async {
    SharedPreferences.setMockInitialValues({
      'remote_omp.profiles.v1': 'not json',
    });
    final store = ProfileStore(await SharedPreferences.getInstance());
    expect(store.readAll(), isEmpty);
    await store.upsert(_profile('1'));
    expect(store.readAll().map((p) => p.id), ['1']);
  });

  test('round-trips the transport, which is no longer derived', () async {
    final store = await _emptyStore();
    await store.upsert(_profile('1'));
    expect(store.readAll().single.isDirect, isTrue);
  });
}

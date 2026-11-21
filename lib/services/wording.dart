import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

/// Whether to use classic player vocabulary ("Play", "Now Playing", "Finished")
/// instead of the Absorb-themed vocabulary ("Absorb", "Absorbing", "Fully
/// Absorbed"). Lives at app level so any widget rebuilds when it flips.
final ValueNotifier<bool> classicWordingNotifier = ValueNotifier(false);

/// Returns either the Absorb-branded localization or the plain player
/// equivalent depending on [classicWordingNotifier].
///
/// Both vocabularies are localized: the classic strings live next to their
/// themed counterparts in the ARB files (`classicAbsorb` beside `absorb`, and
/// so on), so switching the setting never drops a locale back to English. A
/// locale that has not translated the `classic*` keys yet falls back to the
/// English template for those strings only, as everywhere else in the app.
class Wording {
  final AppLocalizations _l;
  final bool classic;
  const Wording._(this._l, this.classic);

  static Wording of(BuildContext context) =>
      Wording._(AppLocalizations.of(context)!, classicWordingNotifier.value);

  /// For code that already holds the strings but has no context to hand -
  /// helpers called from a build method's callee, mostly.
  static Wording from(AppLocalizations l) =>
      Wording._(l, classicWordingNotifier.value);

  // ── Card primary action ──
  String get absorb => classic ? _l.classicAbsorb : _l.absorb;
  String get absorbing => classic ? _l.classicAbsorbing : _l.absorbing;
  String get absorbAgain => classic ? _l.classicAbsorbAgain : _l.absorbAgain;
  String get downloadToAbsorb =>
      classic ? _l.classicDownloadToAbsorb : _l.downloadToAbsorb;
  String get fullyAbsorbed =>
      classic ? _l.classicFullyAbsorbed : _l.fullyAbsorbed;
  String get fullyAbsorbAction =>
      classic ? _l.classicFullyAbsorbAction : _l.fullyAbsorbAction;

  // ── Now Playing list ──
  String get addToAbsorbing =>
      classic ? _l.classicAddToAbsorbing : _l.addToAbsorbing;
  String get absorbNext => classic ? _l.classicAbsorbNext : _l.absorbNext;
  String get absorbLast => classic ? _l.classicAbsorbLast : _l.absorbLast;
  String get absorbNextAdded =>
      classic ? _l.classicAbsorbNextAdded : _l.absorbNextAdded;
  String get removeFromAbsorbing =>
      classic ? _l.classicRemoveFromAbsorbing : _l.removeFromAbsorbing;
  String get addedToAbsorbing =>
      classic ? _l.classicAddedToAbsorbing : _l.addedToAbsorbing;
  String get removedFromAbsorbing =>
      classic ? _l.classicRemovedFromAbsorbing : _l.removedFromAbsorbing;

  String episodeListAddedToAbsorbing(String title) => classic
      ? _l.classicEpisodeListAddedToAbsorbing(title)
      : _l.episodeListAddedToAbsorbing(title);
  String playlistDetailAddedToAbsorbing(String title) => classic
      ? _l.classicPlaylistDetailAddedToAbsorbing(title)
      : _l.playlistDetailAddedToAbsorbing(title);
  String collectionDetailAddedToAbsorbing(String title) => classic
      ? _l.classicCollectionDetailAddedToAbsorbing(title)
      : _l.collectionDetailAddedToAbsorbing(title);
  String sectionDetailAddedToAbsorbing(String title) => classic
      ? _l.classicSectionDetailAddedToAbsorbing(title)
      : _l.sectionDetailAddedToAbsorbing(title);

  // ── Navigation / sections ──
  String get absorbingTitle =>
      classic ? _l.classicAbsorbingTitle : _l.absorbingTitle;
  String get appShellAbsorbingTab =>
      classic ? _l.classicAppShellAbsorbingTab : _l.appShellAbsorbingTab;
  String get startScreenAbsorb =>
      classic ? _l.classicStartScreenAbsorb : _l.startScreenAbsorb;
  String get sectionAbsorbingCards =>
      classic ? _l.classicSectionAbsorbingCards : _l.sectionAbsorbingCards;

  // ── Unified Absorbing page setting ──
  String get mergeLibraries =>
      classic ? _l.classicMergeLibraries : _l.mergeLibraries;
  String get mergeLibrariesInfoTitle =>
      classic ? _l.classicMergeLibrariesInfoTitle : _l.mergeLibrariesInfoTitle;
  String get mergeLibrariesInfoContent => classic
      ? _l.classicMergeLibrariesInfoContent
      : _l.mergeLibrariesInfoContent;
  String get mergeLibrariesOnSubtitle => classic
      ? _l.classicMergeLibrariesOnSubtitle
      : _l.mergeLibrariesOnSubtitle;
  String get mergeLibrariesOffSubtitle => classic
      ? _l.classicMergeLibrariesOffSubtitle
      : _l.mergeLibrariesOffSubtitle;

  // ── Empty / placeholder ──
  String get absorbingNothingAbsorbingYet => classic
      ? _l.classicAbsorbingNothingAbsorbingYet
      : _l.absorbingNothingAbsorbingYet;

  // ── Mark-finished dialogs ──
  String get markAsFullyAbsorbedQuestion => classic
      ? _l.classicMarkAsFullyAbsorbedQuestion
      : _l.markAsFullyAbsorbedQuestion;
  String get fullyAbsorbSeries =>
      classic ? _l.classicFullyAbsorbSeries : _l.fullyAbsorbSeries;

  // ── Settings labels ──
  String get whenAbsorbed =>
      classic ? _l.classicWhenAbsorbed : _l.whenAbsorbed;
  String get whenAbsorbedInfoTitle =>
      classic ? _l.classicWhenAbsorbedInfoTitle : _l.whenAbsorbedInfoTitle;
  String get whenAbsorbedSubtitle => classic
      ? _l.classicWhenAbsorbedSubtitle
      : _l.whenAbsorbedSubtitle;
  String get deleteAbsorbedDownloads =>
      classic ? _l.classicDeleteAbsorbedDownloads : _l.deleteAbsorbedDownloads;
  String get deleteAbsorbedDownloadsInfoTitle => classic
      ? _l.classicDeleteAbsorbedDownloadsInfoTitle
      : _l.deleteAbsorbedDownloadsInfoTitle;

  // ── Login ──
  String get loginTagline =>
      classic ? _l.classicLoginTagline : _l.loginTagline;

  // ── Tips ──
  String get tipsSheetQuickAddAbsorbingTitle => classic
      ? _l.classicTipsSheetQuickAddAbsorbingTitle
      : _l.tipsSheetQuickAddAbsorbingTitle;
  String get tipsSheetQuickAddAbsorbingDesc => classic
      ? _l.classicTipsSheetQuickAddAbsorbingDesc
      : _l.tipsSheetQuickAddAbsorbingDesc;

  // ── Queue mode info popup ──
  String get queueModeInfoManualDesc => classic
      ? _l.classicQueueModeInfoManualDesc
      : _l.queueModeInfoManualDesc;

  String get desktopManualQueueHint => classic
      ? _l.classicDesktopManualQueueHint
      : _l.desktopAbsorbingQueueHint;
}

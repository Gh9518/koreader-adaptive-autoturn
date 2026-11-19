# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Tapping the AutoTurn menu item (or switch) during collection now cancels that collection: AutoTurn stays off, no learned value is written, and you can start again anytime.

### Changed
- Shortened the "Auto setup" page hint to a single line: "Learning your page-turn rhythm, please keep turning pages manually." The 3-second auto-dismiss timing is unchanged.

### Fixed
- Rapid repeated taps on the AutoTurn menu item could stack multiple dialogs and virtual keyboards, which on devices using the third-party `pinyin_enhancement` IME could trigger a KOReader input crash (`inputtext.lua addChars(nil)`). The patch now keeps only one of its own dialogs open at a time, closing any previous one before showing a new dialog or the manual-input box. The underlying crash is in the third-party IME; this reduces the patch-side trigger.

### Performance
- Reduced collection-phase memory: page-turn intervals are now stored as plain numbers instead of per-sample tables with an unused timestamp field; the temporary copy during statistics was removed. Peak sample-array heap for a full 40-sample session drops from ~6.7 KB to ~1.1 KB (−84%) on Lua 5.1. No change to interval computation or learned values.

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Performance
- Reduced collection-phase memory: page-turn intervals are now stored as plain numbers instead of per-sample tables with an unused timestamp field; the temporary copy during statistics was removed. Peak sample-array heap for a full 40-sample session drops from ~6.7 KB to ~1.1 KB (−84%) on Lua 5.1. No change to interval computation or learned values.

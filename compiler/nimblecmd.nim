#
#
#           The Nim Compiler
#        (c) Copyright 2012 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implements some helper procs for Nimble (Nim's package manager) support.

import parseutils, strutils, os, options, msgs, sequtils, lineinfos, pathutils,
  std/sha1, tables

proc addPath*(conf: ConfigRef; path: AbsoluteDir, info: TLineInfo) =
  if not conf.searchPaths.contains(path):
    conf.searchPaths.insert(path, 0)

type
  Version* = distinct string
  PackageInfo = Table[string, tuple[version, checksum: string]]

proc `$`*(ver: Version): string {.borrow.}

proc newVersion*(ver: string): Version =
  doAssert(ver.len == 0 or ver[0] in {'#', '\0'} + Digits,
           "Wrong version: " & ver)
  return Version(ver)

proc isSpecial(ver: Version): bool =
  return ($ver).len > 0 and ($ver)[0] == '#'

proc isValidVersion(v: string): bool =
  if v.len > 0:
    if v[0] in {'#'} + Digits: return true

proc `<`*(ver: Version, ver2: Version): bool =
  ## This is synced from Nimble's version module.

  # Handling for special versions such as "#head" or "#branch".
  if ver.isSpecial or ver2.isSpecial:
    if ver2.isSpecial and ($ver2).normalize == "#head":
      return ($ver).normalize != "#head"

    if not ver2.isSpecial:
      # `#aa111 < 1.1`
      return ($ver).normalize != "#head"

  # Handling for normal versions such as "0.1.0" or "1.0".
  var sVer = string(ver).split('.')
  var sVer2 = string(ver2).split('.')
  for i in 0..<max(sVer.len, sVer2.len):
    var sVerI = 0
    if i < sVer.len:
      discard parseInt(sVer[i], sVerI)
    var sVerI2 = 0
    if i < sVer2.len:
      discard parseInt(sVer2[i], sVerI2)
    if sVerI < sVerI2:
      return true
    elif sVerI == sVerI2:
      discard
    else:
      return false

proc getPathVersionChecksum*(p: string): tuple[name, version, checksum: string] =
  ## Splits path ``p`` in the format
  ## ``/home/user/.nimble/pkgs/package-0.1-febadeaea2345e777f0f6f8433f7f0a52edd5d1b`` into
  ## ``("/home/user/.nimble/pkgs/package", "0.1", "febadeaea2345e777f0f6f8433f7f0a52edd5d1b")``

  const checksumSeparator = '-'
  const versionSeparator = '-'
  const specialVersionSepartator = "-#"
  const separatorNotFound = -1

  var checksumSeparatorIndex = p.rfind(checksumSeparator)
  if checksumSeparatorIndex != separatorNotFound:
    result.checksum = p.substr(checksumSeparatorIndex + 1)
    if not result.checksum.isValidSha1Hash():
      result.checksum = ""
      checksumSeparatorIndex = p.len()
  else:
    checksumSeparatorIndex = p.len()

  var versionSeparatorIndex = p.rfind(
    specialVersionSepartator, 0, checksumSeparatorIndex - 1)
  if versionSeparatorIndex != separatorNotFound:
    result.version = p.substr(
      versionSeparatorIndex + 1, checksumSeparatorIndex - 1)
  else:
    versionSeparatorIndex = p.rfind(
      versionSeparator, 0, checksumSeparatorIndex - 1)
    if versionSeparatorIndex != separatorNotFound:
      result.version = p.substr(
        versionSeparatorIndex + 1, checksumSeparatorIndex - 1)
    else:
      versionSeparatorIndex = checksumSeparatorIndex

  result.name = p[0..<versionSeparatorIndex]

proc addPackage(conf: ConfigRef; packages: var PackageInfo, p: string;
                info: TLineInfo) =
  let (name, ver, checksum) = getPathVersionChecksum(p)
  if isValidVersion(ver):
    let version = newVersion(ver)
    if packages.getOrDefault(name).version.newVersion < version or
      (not packages.hasKey(name)):
      if checksum.isValidSha1Hash():
        packages[name] = ($version, checksum)
      else:
        packages[name] = ($version, "")
  else:
    localError(conf, info, "invalid package name: " & p)

iterator chosen(packages: PackageInfo): string =
  for key, val in pairs(packages):
    var res = key
    if val.version.len != 0:
      res &= '-'
      res &= val.version
    if val.checksum.len != 0:
      res &= '-'
      res &= val.checksum
    yield res

proc addNimblePath(conf: ConfigRef; p: string, info: TLineInfo) =
  var path = p
  let nimbleLinks = toSeq(walkPattern(p / "*.nimble-link"))
  if nimbleLinks.len > 0:
    # If the user has more than one .nimble-link file then... we just ignore it.
    # Spec for these files is available in Nimble's readme:
    # https://github.com/nim-lang/nimble#nimble-link
    let nimbleLinkLines = readFile(nimbleLinks[0]).splitLines()
    path = nimbleLinkLines[1]
    if not path.isAbsolute():
      path = p / path

  if not contains(conf.searchPaths, AbsoluteDir path):
    message(conf, info, hintPath, path)
    conf.lazyPaths.insert(AbsoluteDir path, 0)

proc addPathRec(conf: ConfigRef; dir: string, info: TLineInfo) =
  var packages: PackageInfo
  var pos = dir.len-1
  if dir[pos] in {DirSep, AltSep}: inc(pos)
  for k,p in os.walkDir(dir):
    if k == pcDir and p[pos] != '.':
      addPackage(conf, packages, p, info)
  for p in packages.chosen:
    addNimblePath(conf, p, info)

proc nimblePath*(conf: ConfigRef; path: AbsoluteDir, info: TLineInfo) =
  addPathRec(conf, path.string, info)
  addNimblePath(conf, path.string, info)
  let i = conf.nimblePaths.find(path)
  if i != -1:
    conf.nimblePaths.delete(i)
  conf.nimblePaths.insert(path, 0)

when isMainModule:
  proc v(s: string): Version = s.newVersion
  # #head is special in the sense that it's assumed to always be newest.
  doAssert v"1.0" < v"#head"
  doAssert v"1.0" < v"1.1"
  doAssert v"1.0.1" < v"1.1"
  doAssert v"1" < v"1.1"
  doAssert v"#aaaqwe" < v"1.1" # We cannot assume that a branch is newer.
  doAssert v"#a111" < v"#head"

  proc testAddPackageWithoutChecksum() =
    ## For backward compatibility it is not required all packages to have a
    ## sha1 checksum at the end of the name of the Nimble cache directory.
    ## This way a new compiler will be able to work with an older Nimble.

    let conf = newConfigRef()
    var rr: PackageInfo

    addPackage conf, rr, "irc-#a111", unknownLineInfo()
    addPackage conf, rr, "irc-#head", unknownLineInfo()
    addPackage conf, rr, "irc-0.1.0", unknownLineInfo()

    addPackage conf, rr, "another-0.1", unknownLineInfo()

    addPackage conf, rr, "ab-0.1.3", unknownLineInfo()
    addPackage conf, rr, "ab-0.1", unknownLineInfo()
    addPackage conf, rr, "justone-1.0", unknownLineInfo()

    doAssert toSeq(rr.chosen).toHashSet ==
      ["irc-#head", "another-0.1", "ab-0.1.3", "justone-1.0"].toHashSet

  proc testAddPackageWithChecksum() =
    let conf = newConfigRef()
    var rr: PackageInfo

    # in the case of packages with the same version, but different checksums for
    # now the first one will be chosen

    addPackage conf, rr, "irc-#a111-DBC1F902CB79946E990E38AF51F0BAD36ACFABD9",
               unknownLineInfo()
    addPackage conf, rr, "irc-#head-042D4BE2B90ED0672E717D71850ABDB0A2D19CD1",
               unknownLineInfo()
    addPackage conf, rr, "irc-#head-042D4BE2B90ED0672E717D71850ABDB0A2D19CD2",
               unknownLineInfo()
    addPackage conf, rr, "irc-0.1.0-6EE6DE936B32E82C7DBE526DA3463574F6568FAF",
               unknownLineInfo()

    addPackage conf, rr, "another-0.1", unknownLineInfo()
    addPackage conf, rr, "another-0.1-F07EE6040579F0590608A8FD34F5F2D91D859340",
               unknownLineInfo()

    addPackage conf, rr, "ab-0.1.3-34BC3B72CE46CF5A496D1121CFEA7369385E9EA2",
               unknownLineInfo()
    addPackage conf, rr, "ab-0.1.3-24BC3B72CE46CF5A496D1121CFEA7369385E9EA2",
               unknownLineInfo()
    addPackage conf, rr, "ab-0.1-A3CFFABDC4759F7779D541F5E031AED17169390A",
               unknownLineInfo()

    # lower case hex digits is also a valid sha1 checksum
    addPackage conf, rr, "justone-1.0-f07ee6040579f0590608a8fd34f5f2d91d859340",
               unknownLineInfo()

    doAssert toSeq(rr.chosen).toHashSet == [
      "irc-#head-042D4BE2B90ED0672E717D71850ABDB0A2D19CD1",
      "another-0.1",
      "ab-0.1.3-34BC3B72CE46CF5A496D1121CFEA7369385E9EA2",
      "justone-1.0-f07ee6040579f0590608a8fd34f5f2d91d859340"
      ].toHashSet

  testAddPackageWithoutChecksum()
  testAddPackageWithChecksum()

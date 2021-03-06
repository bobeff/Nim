discard """
  cmd: "nim $target --threads:on -d:release -d:useRealtimeGC $options $file"
  joinable:false
"""

#[
was: cmd: "nim $target --debuginfo $options $file"
these dont' seem needed --debuginfo
nor these from the previous main.nim.cfg: --app:console
]#

import times, os, strformat, strutils
from stdtest/specialpaths import buildDir
# import threadpool

const runtimeSecs {.intdefine.} = 5

const file = "shared.nim"
const dllname = buildDir / (DynlibFormat % file)

static:
  let nim = getCurrentCompilerExe()
  let (output, exitCode) = gorgeEx(fmt"{nim} c -o:{dllname} --debuginfo --app:lib --threads:on -d:release -d:useRealtimeGC {file}")
  doAssert exitCode == 0, output

proc status() {.importc: "status", dynlib: dllname.}
proc count() {.importc: "count", dynlib: dllname.}
proc checkOccupiedMem() {.importc: "checkOccupiedMem", dynlib: dllname.}

proc process() =
  let startTime = getTime()
  let runTime = cast[Time](runtimeSecs)
  var accumTime: Time
  while accumTime < runTime:
    for i in 0..10:
      count()
    # echo("1. sleeping... ")
    sleep(500)
    for i in 0..10:
      status()
    # echo("2. sleeping... ")
    sleep(500)
    checkOccupiedMem()
    accumTime = cast[Time]((getTime() - startTime))
    # echo("--- Minutes left to run: ", int(int(runTime-accumTime)/60))

proc main() =
  process()
  # parallel:
  #   for i in 0..0:
  #     spawn process()
  # sync()

main()

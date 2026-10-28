//// Contract tests for `screwtape/argv`'s `classify` verb (PHASE-13 T2, EX-1;
//// design § 5.2 CLI).
////
//// `classify` takes no argument, or exactly `--state`: anything else is the
//// same `Usage("unexpected_argument")` the other argument-less verbs give.

import gleam/list
import gleeunit
import gleeunit/should
import screwtape/argv
import screwtape/error

pub fn main() -> Nil {
  gleeunit.main()
}

const path = "/home/operator/.config/screwtape/config.json"

pub fn classify_test() {
  argv.parse(["--config", path, "classify"])
  |> should.equal(Ok(argv.Command(path, argv.Classify(False))))

  argv.parse(["--config", path, "classify", "--state"])
  |> should.equal(Ok(argv.Command(path, argv.Classify(True))))
}

pub fn classify_rejections_test() {
  let cases = [
    ["--config", path, "classify", "--state", "--state"],
    ["--config", path, "classify", "x"],
    ["--config", path, "classify", "--state", "x"],
  ]

  list.each(cases, fn(args) {
    argv.parse(args)
    |> should.equal(Error(error.Usage("unexpected_argument")))
  })
}

//// VT-5: the Jev codec (PHASE-12, T4; design § 5.2 `screwtape/jev`).
////
//// Every failure is a `Decode(path)` whose path is built only from our own
//// question names and labels — never a key or a value from the reply. The
//// fixture reply is spec-derived (see `test/fixtures/jev/PROVENANCE.md`).

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import screwtape/classify/schema
import screwtape/error.{type Error, Decode}
import screwtape/file
import screwtape/jev

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// The request shape
// ---------------------------------------------------------------------------

pub fn request_body_has_the_three_question_shapes_test() {
  let document = request_document()
  text(document, ["model"]) |> should.equal("typesafe/jev-1.14.0")
  // The state is passed through untouched.
  decode.run(document, decode.at(["state", "k"], decode.int))
  |> should.equal(Ok(1))
  decode.run(document, decode.at(["state", "questions"], decode.dynamic))
  |> should.be_error
  // A choice: type, instructions, criteria as `{label: description}`.
  text(document, ["questions", "primary_purpose", "type"])
  |> should.equal("choice")
  text(document, ["questions", "primary_purpose", "instructions"])
  |> should.equal("What is it?")
  text(document, ["questions", "primary_purpose", "criteria", "a"])
  |> should.equal("Description A")
  text(document, ["questions", "primary_purpose", "criteria", "b"])
  |> should.equal("Description B")
  // A noul: no criteria key at all.
  text(document, ["questions", "security_related", "type"])
  |> should.equal("noul")
  text(document, ["questions", "security_related", "instructions"])
  |> should.equal("Is it?")
  decode.run(
    document,
    decode.at(["questions", "security_related", "criteria"], decode.dynamic),
  )
  |> should.be_error
  // A score: criteria is the level array, in order.
  text(document, ["questions", "substance", "type"]) |> should.equal("score")
  text(document, ["questions", "substance", "instructions"])
  |> should.equal("How much?")
  decode.run(
    document,
    decode.at(
      ["questions", "substance", "criteria"],
      decode.list(decode.string),
    ),
  )
  |> should.equal(Ok(["none", "some"]))
}

// ---------------------------------------------------------------------------
// The fixture reply
// ---------------------------------------------------------------------------

pub fn fixture_reply_decodes_with_the_prefixed_model_test() {
  list.each(
    [decode_fixture("typesafe/jev-1.14.0"), decode_fixture("jev-1.14.0")],
    fn(reply) {
      reply.answers
      |> list.map(fn(entry) { jev_question_name(entry.0) })
      |> should.equal(mail_1_names())
      // Every answer, in full: our label order, every probability, both scores.
      reply.answers
      |> list.map(fn(entry) { entry.1 })
      |> should.equal([
        jev.ChoiceAnswer("correspondence", 0.81, [
          #("correspondence", 0.72),
          #("payment_due", 0.1),
          #("payment_record", 0.05),
          #("service_notice", 0.08),
          #("editorial", 0.02),
          #("promotion", 0.02),
          #("other", 0.01),
        ]),
        jev.NoulAnswer(0.97),
        jev.NoulAnswer(0.88),
        jev.NoulAnswer(0.12),
        jev.NoulAnswer(0.0),
        jev.NoulAnswer(0.03),
        jev.ScoreAnswer(0.15, 0.9, [0.85, 0.15, 0.0]),
        jev.ScoreAnswer(1.2, 0.75, [0.0, 0.8, 0.2]),
      ])
    },
  )
}

fn mail_1_names() -> List(String) {
  [
    "primary_purpose",
    "security_related",
    "recipient_action_requested",
    "deadline_present",
    "deception_cues",
    "agent_directive",
    "claimed_time_pressure",
    "substance",
  ]
}

// ---------------------------------------------------------------------------
// Hostile replies: each failure names our own path exactly
// ---------------------------------------------------------------------------

pub fn wrong_type_test() {
  reply_with(noul_answer(0.5), good_noul(), good_score())
  |> should_fail("answers.primary_purpose.type")
}

pub fn unknown_choice_test() {
  reply_with(
    choice_answer("c", 0.9, [#("a", 0.8), #("b", 0.2)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.choice")
}

pub fn non_argmax_choice_test() {
  reply_with(
    choice_answer("b", 0.9, [#("a", 0.8), #("b", 0.2)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.choice")
}

pub fn argmax_tie_is_accepted_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 0.5), #("b", 0.5)]),
    good_noul(),
    good_score(),
  )
  |> decode_reply
  |> should.be_ok
}

pub fn probability_out_of_range_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 1.2), #("b", -0.2)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.probabilities.a")
}

pub fn missing_probability_key_test() {
  reply_with(choice_answer("a", 0.9, [#("a", 1.0)]), good_noul(), good_score())
  |> should_fail("answers.primary_purpose.probabilities.b")
}

pub fn extra_probability_key_is_ignored_test() {
  let reply =
    reply_with(
      choice_answer("a", 0.9, [#("a", 0.7), #("b", 0.3), #("c", 0.2)]),
      good_noul(),
      good_score(),
    )
    |> decode_reply
  let assert Ok(reply) = reply
  let assert [#(_, jev.ChoiceAnswer(_, _, probabilities)), ..] = reply.answers
  probabilities |> should.equal([#("a", 0.7), #("b", 0.3)])
}

pub fn extra_probability_key_with_no_mass_is_ignored_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 0.8), #("b", 0.2), #("c", 0.0)]),
    good_noul(),
    good_score(),
  )
  |> decode_reply
  |> should.be_ok
}

pub fn non_normalised_probabilities_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 0.5), #("b", 0.4)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.probabilities")
}

pub fn probability_sum_at_the_tolerance_is_accepted_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 0.49), #("b", 0.49)]),
    good_noul(),
    good_score(),
  )
  |> decode_reply
  |> should.be_ok
}

pub fn probability_sum_beyond_the_tolerance_is_rejected_test() {
  reply_with(
    choice_answer("a", 0.9, [#("a", 0.49), #("b", 0.48)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.probabilities")
}

pub fn score_at_the_tolerance_is_accepted_test() {
  reply_with(
    good_choice(),
    good_noul(),
    score_answer(0.55, 0.9, [#("0", 0.5), #("1", 0.5)]),
  )
  |> decode_reply
  |> should.be_ok
}

pub fn score_beyond_the_tolerance_is_rejected_test() {
  reply_with(
    good_choice(),
    good_noul(),
    score_answer(0.56, 0.9, [#("0", 0.5), #("1", 0.5)]),
  )
  |> should_fail("answers.substance.score")
}

pub fn huge_integer_noul_fails_the_number_decoder_test() {
  let digits = string.repeat("9", 400)
  let text =
    "{\"model\":\"jev-1.14.0\",\"answers\":{\"primary_purpose\":"
    <> json.to_string(good_choice())
    <> ",\"security_related\":{\"type\":\"noul\",\"noul\":"
    <> digits
    <> "},\"substance\":"
    <> json.to_string(good_score())
    <> "}}"
  decode_reply(text)
  |> should.equal(Error(Decode("answers.security_related.noul")))
}

pub fn inconsistent_score_test() {
  reply_with(
    good_choice(),
    good_noul(),
    score_answer(0.8, 0.9, [#("0", 0.5), #("1", 0.5)]),
  )
  |> should_fail("answers.substance.score")
}

pub fn score_out_of_range_test() {
  reply_with(
    good_choice(),
    good_noul(),
    score_answer(2.0, 0.9, [#("0", 1.0), #("1", 0.0)]),
  )
  |> should_fail("answers.substance.score")
}

pub fn confidence_out_of_range_test() {
  reply_with(
    choice_answer("a", 1.5, [#("a", 0.8), #("b", 0.2)]),
    good_noul(),
    good_score(),
  )
  |> should_fail("answers.primary_purpose.confidence")
}

pub fn noul_out_of_range_test() {
  reply_with(good_choice(), noul_answer(1.2), good_score())
  |> should_fail("answers.security_related.noul")
}

pub fn other_model_test() {
  reply_json("jev-1.13.0", test_answers())
  |> decode_reply
  |> should.equal(Error(Decode("model")))
}

/// A model that is not ours must not leak into the error, even key-shaped.
pub fn key_shaped_model_never_appears_in_the_error_test() {
  let sentinel = "sk-ts-0123abcd"
  let error =
    reply_json(sentinel, test_answers())
    |> decode_reply
    |> should.be_error
  error |> should.equal(Decode("model"))
  string.inspect(error) |> string.contains(sentinel) |> should.be_false
}

pub fn prefixed_other_model_test() {
  reply_json("other/jev-1.14.0", test_answers())
  |> decode_reply
  |> should.equal(Error(Decode("model")))
}

pub fn non_object_replies_are_the_root_path_test() {
  list.each(["[]", "\"x\"", "not json"], fn(text) {
    decode_reply(text) |> should.equal(Error(Decode("$")))
  })
}

pub fn missing_answer_test() {
  reply_json("jev-1.14.0", [
    #("primary_purpose", good_choice()),
    #("substance", good_score()),
  ])
  |> should_fail("answers.security_related.type")
}

// ---------------------------------------------------------------------------
// Helpers: the test's own question set
// ---------------------------------------------------------------------------

fn test_questions() -> List(jev.Question) {
  [
    jev.Choice("primary_purpose", "What is it?", [
      #("a", "Description A"),
      #("b", "Description B"),
    ]),
    jev.Noul("security_related", "Is it?"),
    jev.Score("substance", "How much?", ["none", "some"]),
  ]
}

fn request_document() -> Dynamic {
  let assert Ok(document) =
    jev.request_body(
      "typesafe/jev-1.14.0",
      json.object([#("k", json.int(1))]),
      test_questions(),
    )
    |> json.parse(using: decode.dynamic)
  document
}

fn text(document: Dynamic, path: List(String)) -> String {
  let assert Ok(value) = decode.run(document, decode.at(path, decode.string))
  value
}

fn decode_fixture(model: String) -> jev.Reply {
  let assert Ok(text) = file.read_text("test/fixtures/jev/mail-1-reply.json")
  let assert Ok(reply) = jev.reply(text, schema.mail_1(), model)
  reply
}

fn decode_reply(text: String) -> Result(jev.Reply, Error) {
  jev.reply(text, test_questions(), "typesafe/jev-1.14.0")
}

fn should_fail(text: String, path: String) -> Nil {
  decode_reply(text) |> should.equal(Error(Decode(path)))
}

// ---------------------------------------------------------------------------
// Helpers: reply text
// ---------------------------------------------------------------------------

fn test_answers() -> List(#(String, Json)) {
  [
    #("primary_purpose", good_choice()),
    #("security_related", good_noul()),
    #("substance", good_score()),
  ]
}

fn reply_with(choice: Json, noul: Json, score: Json) -> String {
  reply_json("jev-1.14.0", [
    #("primary_purpose", choice),
    #("security_related", noul),
    #("substance", score),
  ])
}

fn reply_json(model: String, answers: List(#(String, Json))) -> String {
  json.object([
    #("model", json.string(model)),
    #("answers", json.object(answers)),
    #(
      "usage",
      json.object([
        #("input_tokens", json.int(10)),
        #("output_tokens", json.int(2)),
      ]),
    ),
  ])
  |> json.to_string
}

fn good_choice() -> Json {
  choice_answer("a", 0.9, [#("a", 0.8), #("b", 0.2)])
}

fn good_noul() -> Json {
  noul_answer(0.5)
}

fn good_score() -> Json {
  score_answer(0.5, 0.8, [#("0", 0.5), #("1", 0.5)])
}

fn choice_answer(
  choice: String,
  confidence: Float,
  probabilities: List(#(String, Float)),
) -> Json {
  json.object([
    #("type", json.string("choice")),
    #("choice", json.string(choice)),
    #("confidence", json.float(confidence)),
    #("probabilities", json.object(list.map(probabilities, probability_field))),
  ])
}

fn noul_answer(noul: Float) -> Json {
  json.object([
    #("type", json.string("noul")),
    #("noul", json.float(noul)),
  ])
}

fn score_answer(
  score: Float,
  confidence: Float,
  probabilities: List(#(String, Float)),
) -> Json {
  json.object([
    #("type", json.string("score")),
    #("score", json.float(score)),
    #("confidence", json.float(confidence)),
    #("probabilities", json.object(list.map(probabilities, probability_field))),
  ])
}

fn probability_field(entry: #(String, Float)) -> #(String, Json) {
  #(entry.0, json.float(entry.1))
}

// ---------------------------------------------------------------------------
// Helpers: question accessors
// ---------------------------------------------------------------------------

fn jev_question_name(question: jev.Question) -> String {
  case question {
    jev.Choice(name, _, _) -> name
    jev.Noul(name, _) -> name
    jev.Score(name, _, _) -> name
  }
}

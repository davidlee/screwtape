//// The Jev request and reply codec (PHASE-12, T4/EX-11..EX-14; design § 5.2).
////
//// `request_body` writes the one shape Jev accepts: the model, the classified
//// state and the questions, each with its type (`choice`, `noul`, `score`) and
//// only the criteria key that type has.
////
//// `reply` reads answers by our own question names with `decode.at`, one path
//// per known question, and never by iterating the reply's keys. A failure is a
//// `Decode(path)` whose path is built only from our question names and labels,
//// never from the reply, so a reply can never put its own text into an `Error`.
//// Extra answers, extra probability keys and `usage`/`legend` are ignored.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import screwtape/error.{type Error, Decode}

/// How far a probability set's sum may sit from 1 (design § 5.2; A1 confirms).
pub const probability_tolerance = 0.02

/// How far a score may sit from the probability-weighted level (A1 confirms).
pub const score_tolerance = 0.05

/// The location of a value that is not a JSON object at all.
const root = "$"

/// The largest JSON integer accepted where a float is expected: a bigger one is
/// refused rather than converted, because it does not survive the conversion.
const max_integer = 1_000_000

/// How much a difference may exceed a tolerance: floats cannot add their way to
/// a bound exactly, so a boundary case is accepted.
const float_slack = 1.0e-9

/// `dynamic.classify`'s name for a JSON object.
const object_classification = "Dict"

/// One question the classifier asks Jev. `Choice` criteria are
/// `#(label, description)` in the order Jev should see them; `Score` levels
/// are the level descriptions in index order.
pub type Question {
  Choice(name: String, instructions: String, criteria: List(#(String, String)))
  Noul(name: String, instructions: String)
  Score(name: String, instructions: String, levels: List(String))
}

/// Jev's answer to one question: the choice and its distribution, the noul
/// probability, or the score and its distribution. Probabilities keep our label
/// or level order.
pub type Answer {
  ChoiceAnswer(
    choice: String,
    confidence: Float,
    probabilities: List(#(String, Float)),
  )
  NoulAnswer(noul: Float)
  ScoreAnswer(score: Float, confidence: Float, probabilities: List(Float))
}

/// A whole reply: the model Jev reported and one answer per question, in our
/// order.
pub type Reply {
  Reply(model: String, answers: List(#(Question, Answer)))
}

/// The JSON body of the one POST: `{"model", "state", "questions"}`, where each
/// question is `{"type", "instructions", "criteria"?}` in our order.
pub fn request_body(
  model: String,
  state: Json,
  questions: List(Question),
) -> String {
  json.object([
    #("model", json.string(model)),
    #("state", state),
    #("questions", json.object(list.map(questions, question_entry))),
  ])
  |> json.to_string
}

/// Decode a reply. Not JSON, or JSON that is not an object, is `Decode("$")`; a
/// `model` that is neither the configured model nor its text after the last `/`
/// is `Decode("model")`. An answer that is missing, mistyped or inconsistent is
/// a `Decode` path built from our own question name and field.
pub fn reply(
  text: String,
  questions: List(Question),
  model: String,
) -> Result(Reply, Error) {
  case json.parse(text, using: decode.dynamic) {
    Error(_) -> Error(Decode(root))
    Ok(document) ->
      case dynamic.classify(document) == object_classification {
        False -> Error(Decode(root))
        True -> decode_document(document, questions, model)
      }
  }
}

// ---------------------------------------------------------------------------
// The document
// ---------------------------------------------------------------------------

fn decode_document(
  document: Dynamic,
  questions: List(Question),
  model: String,
) -> Result(Reply, Error) {
  use found_model <- result.try(
    decode.run(document, decode.at(["model"], decode.string))
    |> result.replace_error(Decode("model")),
  )
  case model_matches(found_model, model) {
    False -> Error(Decode("model"))
    True -> {
      use answers <- result.try(
        decode.run(document, decode.at(["answers"], decode.dynamic))
        |> result.replace_error(Decode("answers")),
      )
      use decoded <- result.try(decode_answers(answers, questions))
      Ok(Reply(model: found_model, answers: decoded))
    }
  }
}

/// A gateway may answer with the bare model while the configuration carries a
/// provider prefix: accept the configured model itself or its last segment.
fn model_matches(found: String, model: String) -> Bool {
  found == model || found == after_last_slash(model)
}

fn after_last_slash(model: String) -> String {
  case model |> string.split("/") |> list.last {
    Ok(last) -> last
    Error(_) -> model
  }
}

fn decode_answers(
  answers: Dynamic,
  questions: List(Question),
) -> Result(List(#(Question, Answer)), Error) {
  questions
  |> list.try_map(fn(question) {
    answer(answers, question)
    |> result.map(fn(answer) { #(question, answer) })
  })
}

// ---------------------------------------------------------------------------
// One answer
// ---------------------------------------------------------------------------

fn answer(answers: Dynamic, question: Question) -> Result(Answer, Error) {
  let name = question_name(question)
  use type_ <- result.try(field_string(answers, name, "type"))
  case type_ == question_type(question) {
    False -> Error(Decode(path(name, "type")))
    True ->
      case question {
        Choice(_, _, criteria) -> choice_answer(answers, name, criteria)
        Noul(..) -> noul_answer(answers, name)
        Score(_, _, levels) -> score_answer(answers, name, levels)
      }
  }
}

fn choice_answer(
  answers: Dynamic,
  name: String,
  criteria: List(#(String, String)),
) -> Result(Answer, Error) {
  let labels = list.map(criteria, fn(criterion) { criterion.0 })
  let choice_path = path(name, "choice")
  use choice <- result.try(
    decode.run(answers, decode.at([name, "choice"], decode.string))
    |> result.replace_error(Decode(choice_path)),
  )
  case list.contains(labels, choice) {
    False -> Error(Decode(choice_path))
    True -> {
      use values <- result.try(probabilities(answers, name, labels))
      use confidence <- result.try(confidence(answers, name))
      let probabilities = list.zip(labels, values)
      case is_argmax(choice, probabilities) {
        False -> Error(Decode(choice_path))
        True ->
          Ok(ChoiceAnswer(
            choice: choice,
            confidence: confidence,
            probabilities: probabilities,
          ))
      }
    }
  }
}

fn noul_answer(answers: Dynamic, name: String) -> Result(Answer, Error) {
  use noul <- result.try(field_number(answers, name, "noul"))
  case in_unit_range(noul) {
    True -> Ok(NoulAnswer(noul: noul))
    False -> Error(Decode(path(name, "noul")))
  }
}

fn score_answer(
  answers: Dynamic,
  name: String,
  levels: List(String),
) -> Result(Answer, Error) {
  // A score's probability keys are the level indices, `"0"`..`"n-1"`.
  let keys = list.index_map(levels, fn(_, index) { int.to_string(index) })
  use probabilities <- result.try(probabilities(answers, name, keys))
  use score <- result.try(field_number(answers, name, "score"))
  use confidence <- result.try(confidence(answers, name))
  let score_path = path(name, "score")
  let highest = int.to_float(list.length(levels) - 1)
  case score >=. 0.0 && score <=. highest {
    False -> Error(Decode(score_path))
    True ->
      case
        within(
          float.absolute_value(score -. weighted_score(probabilities)),
          score_tolerance,
        )
      {
        True ->
          Ok(ScoreAnswer(
            score: score,
            confidence: confidence,
            probabilities: probabilities,
          ))
        False -> Error(Decode(score_path))
      }
  }
}

/// A choice must be at least tied for the highest probability.
fn is_argmax(choice: String, probabilities: List(#(String, Float))) -> Bool {
  case list.find(probabilities, fn(entry) { entry.0 == choice }) {
    Ok(#(_, chosen)) ->
      list.all(probabilities, fn(entry) { chosen >=. entry.1 })
    Error(_) -> False
  }
}

/// The sum of `i * p_i`, the level a score's distribution implies.
fn weighted_score(probabilities: List(Float)) -> Float {
  probabilities
  |> list.index_map(fn(probability, index) {
    int.to_float(index) *. probability
  })
  |> float.sum
}

// ---------------------------------------------------------------------------
// Fields and probabilities
// ---------------------------------------------------------------------------

fn confidence(answers: Dynamic, name: String) -> Result(Float, Error) {
  use confidence <- result.try(field_number(answers, name, "confidence"))
  case in_unit_range(confidence) {
    True -> Ok(confidence)
    False -> Error(Decode(path(name, "confidence")))
  }
}

/// Our keys' probabilities in the given key order, each in [0, 1] and summing
/// to 1 within the tolerance. Only our keys are read: any other key the reply
/// carries is ignored, whatever mass it claims.
fn probabilities(
  answers: Dynamic,
  name: String,
  keys: List(String),
) -> Result(List(Float), Error) {
  use values <- result.try(
    list.try_map(keys, fn(key) {
      use value <- result.try(
        decode.run(answers, decode.at([name, "probabilities", key], number()))
        |> result.replace_error(Decode(path(name, "probabilities." <> key))),
      )
      case in_unit_range(value) {
        True -> Ok(value)
        False -> Error(Decode(path(name, "probabilities." <> key)))
      }
    }),
  )
  case
    within(
      float.absolute_value(float.sum(values) -. 1.0),
      probability_tolerance,
    )
  {
    True -> Ok(values)
    False -> Error(Decode(path(name, "probabilities")))
  }
}

fn in_unit_range(value: Float) -> Bool {
  value >=. 0.0 && value <=. 1.0
}

/// A difference is within its tolerance when it does not exceed it beyond the
/// float slack, so an exact boundary case is accepted.
fn within(diff: Float, tolerance: Float) -> Bool {
  diff <=. tolerance +. float_slack
}

/// The one number decoder: JSON ints are accepted where a float is expected.
fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.then(int_number)])
}

fn int_number(value: Int) -> decode.Decoder(Float) {
  case value >= 0 && value <= max_integer {
    True -> decode.success(int.to_float(value))
    False -> decode.failure(0.0, "an integer no larger than the bound")
  }
}

fn field_string(
  answers: Dynamic,
  name: String,
  field: String,
) -> Result(String, Error) {
  decode.run(answers, decode.at([name, field], decode.string))
  |> result.replace_error(Decode(path(name, field)))
}

fn field_number(
  answers: Dynamic,
  name: String,
  field: String,
) -> Result(Float, Error) {
  decode.run(answers, decode.at([name, field], number()))
  |> result.replace_error(Decode(path(name, field)))
}

fn path(name: String, field: String) -> String {
  "answers." <> name <> "." <> field
}

// ---------------------------------------------------------------------------
// The question shapes
// ---------------------------------------------------------------------------

fn question_entry(question: Question) -> #(String, Json) {
  case question {
    Choice(name, instructions, criteria) -> #(
      name,
      json.object([
        #("type", json.string("choice")),
        #("instructions", json.string(instructions)),
        #("criteria", json.object(list.map(criteria, criterion_entry))),
      ]),
    )
    Noul(name, instructions) -> #(
      name,
      json.object([
        #("type", json.string("noul")),
        #("instructions", json.string(instructions)),
      ]),
    )
    Score(name, instructions, levels) -> #(
      name,
      json.object([
        #("type", json.string("score")),
        #("instructions", json.string(instructions)),
        #("criteria", json.array(levels, json.string)),
      ]),
    )
  }
}

fn criterion_entry(criterion: #(String, String)) -> #(String, Json) {
  #(criterion.0, json.string(criterion.1))
}

/// Our name for a question: the key its answer is stored and printed under.
pub fn question_name(question: Question) -> String {
  case question {
    Choice(name, ..) -> name
    Noul(name, ..) -> name
    Score(name, ..) -> name
  }
}

fn question_type(question: Question) -> String {
  case question {
    Choice(..) -> "choice"
    Noul(..) -> "noul"
    Score(..) -> "score"
  }
}

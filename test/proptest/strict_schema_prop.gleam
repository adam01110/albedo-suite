//// OpenAI tool strictness: `strict` is claimed only when every object schema
//// reachable through any JSON Schema applicator closes additionalProperties
//// and requires all of its properties. The generator builds schemas whose
//// expected strictness it knows by construction; values under annotation
//// keywords (const, default, enum, examples) are data, not schemas.

import albedo_model as types
import albedo_openai/request
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/string
import proptest
import qcheck

/// A schema and whether it satisfies the strict rules.
pub type Node {
  Node(json: Json, strict: Bool, text: String)
}

fn pick(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn leaf() -> qcheck.Generator(Node) {
  pick([
    Node(json.object([#("type", json.string("string"))]), True, "string"),
    Node(json.object([#("type", json.string("integer"))]), True, "integer"),
    Node(json.bool(True), True, "true"),
    Node(json.object([]), True, "{}"),
  ])
}

/// An open object: the smallest schema strict mode refuses.
fn open_object() -> Node {
  Node(
    json.object([
      #("type", json.string("object")),
      #("properties", json.object([#("x", json.object([#("type", json.string("string"))]))])),
    ]),
    False,
    "open",
  )
}

fn object(depth: Int) -> qcheck.Generator(Node) {
  use children, required_shape, closing, typing <- qcheck.map4(
    qcheck.generic_list(node(depth - 1), qcheck.bounded_int(0, 3)),
    pick(["all", "all", "missing", "extra"]),
    pick(["false", "false", "false", "absent", "true", "schema"]),
    pick(["object", "object", "nullable", "untyped"]),
  )
  let names = list.index_map(children, fn(_, i) { "p" <> int.to_string(i) })
  let required = case required_shape, names {
    "missing", [_, ..rest] -> rest
    "extra", _ -> ["zz", ..names]
    _, _ -> names
  }
  let typing = case typing, children {
    // Without a type or properties nothing marks the schema as an object.
    "untyped", [] -> "object"
    _, _ -> typing
  }
  let type_field = case typing {
    "object" -> [#("type", json.string("object"))]
    "nullable" -> [#("type", json.array(["object", "null"], json.string))]
    _ -> []
  }
  let #(closing_field, closed) = case closing {
    "false" -> #([#("additionalProperties", json.bool(False))], True)
    "true" -> #([#("additionalProperties", json.bool(True))], False)
    "schema" -> #([#("additionalProperties", json.object([#("type", json.string("string"))]))], False)
    _ -> #([], False)
  }
  let complete = list.all(names, list.contains(required, _))
  let fields =
    list.flatten([
      type_field,
      [
        #("properties", json.object(list.zip(names, list.map(children, fn(c) { c.json })))),
        #("required", json.array(required, json.string)),
      ],
      closing_field,
    ])
  let strict = closed && complete && list.all(children, fn(c) { c.strict })
  Node(json.object(fields), strict, "object(" <> closing <> "," <> required_shape <> ")[" <> string.join(list.map(children, fn(c) { c.text }), ",") <> "]")
}

const single = ["items", "not", "if", "then", "else", "contains", "additionalItems", "propertyNames", "unevaluatedItems", "unevaluatedProperties"]

const many = ["anyOf", "oneOf", "allOf", "prefixItems", "items"]

const named = ["$defs", "definitions", "patternProperties", "dependentSchemas", "dependencies"]

/// Data keywords: object values below them are never schemas.
const data = ["const", "default", "examples", "enum"]

fn applicator(depth: Int) -> qcheck.Generator(Node) {
  use kind <- qcheck.bind(pick(["single", "many", "named", "data"]))
  case kind {
    "single" -> {
      use keyword, child <- qcheck.map2(pick(single), node(depth - 1))
      Node(json.object([#(keyword, child.json)]), child.strict, keyword <> ":" <> child.text)
    }
    "many" -> {
      use keyword, children <- qcheck.map2(pick(many), qcheck.generic_list(node(depth - 1), qcheck.bounded_int(1, 3)))
      Node(
        json.object([#(keyword, json.preprocessed_array(list.map(children, fn(c) { c.json })))]),
        list.all(children, fn(c) { c.strict }),
        keyword <> ":[" <> string.join(list.map(children, fn(c) { c.text }), ",") <> "]",
      )
    }
    "named" -> {
      use keyword, child <- qcheck.map2(pick(named), node(depth - 1))
      Node(json.object([#(keyword, json.object([#("k", child.json)]))]), child.strict, keyword <> ":{k:" <> child.text <> "}")
    }
    _ -> {
      // An open object as data leaves strictness to the rest of the schema.
      use keyword, child <- qcheck.map2(pick(data), node(depth - 1))
      let value = case keyword {
        "enum" | "examples" -> json.preprocessed_array([open_object().json])
        _ -> open_object().json
      }
      Node(json.object([#(keyword, value), #("allOf", json.preprocessed_array([child.json]))]), child.strict, keyword <> "+" <> child.text)
    }
  }
}

pub fn node(depth: Int) -> qcheck.Generator(Node) {
  case depth <= 0 {
    True -> qcheck.from_weighted_generators(#(4, leaf()), [#(1, qcheck.return(open_object()))])
    False ->
      qcheck.from_weighted_generators(#(2, leaf()), [
        #(1, qcheck.return(open_object())),
        #(3, object(depth)),
        #(3, applicator(depth)),
      ])
  }
}

fn claimed(protocol: types.Protocol, parameters: Json) -> Bool {
  let encoded = request.encode_tools(protocol, [types.Tool("t", "", parameters, True)]) |> json.to_string
  let path = case protocol {
    types.Responses -> ["strict"]
    types.ChatCompletions -> ["function", "strict"]
  }
  let assert Ok([strict]) = json.parse(encoded, decode.list(decode.at(path, decode.bool)))
  strict
}

pub fn main() -> Nil {
  proptest.check("strict is claimed iff every reachable object is closed and complete", 100, qcheck.tuple2(node(3), qcheck.bool()), fn(input) {
    let #(schema, chat) = input
    let protocol = case chat {
      True -> types.ChatCompletions
      False -> types.Responses
    }
    proptest.bump(case schema.strict {
      True -> "strict"
      False -> "not_strict"
    })
    let found = claimed(protocol, schema.json)
    case found == schema.strict {
      True -> Nil
      False -> panic as { "claimed " <> string.inspect(found) <> " for " <> schema.text <> ": " <> json.to_string(schema.json) }
    }
  })

  // A tool that does not ask for strict mode never gets it.
  proptest.check("strict is never claimed for a non-strict tool", 20, node(2), fn(schema) {
    let encoded = request.encode_tools(types.Responses, [types.Tool("t", "", schema.json, False)]) |> json.to_string
    assert json.parse(encoded, decode.list(decode.at(["strict"], decode.bool))) == Ok([False])
  })
}

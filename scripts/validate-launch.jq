def safe_string:
  type == "string" and (contains("\u0000") | not);

def environment:
  type == "object" and (to_entries | all(.[];
    (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and
    (.value | safe_string)));

length == 1 and (.[0] |
  type == "object" and
  (.command | safe_string and length > 0) and
  (.args | type == "array" and all(.[]; safe_string)) and
  (.runtimePath | safe_string) and
  (.environment | environment) and
  (.secrets | environment))

-- This file was automatically generated for the LuaDist project.

package = "kong-segment-log"
version = "0.1.0-2"
-- LuaDist source
source = {
  tag = "0.1.0-2",
  url = "git://github.com/LuaDist-testing/kong-segment-log.git"
}
-- Original source
-- source = {
--   url = "git://github.com/DigitalGlobe/kong-segment-log",
--   tag = "v0.1.0-2",
-- }
description = {
  summary = "A Kong plugin that sends request logs to Segment track() API to track user activity.",
  license = "MIT"
}
dependencies = {
  "lua ~> 5.1"
  -- If you depend on other rocks, add them here
}
build = {
  type = "builtin",
  modules = {
    ["kong.plugins.segment-log.schema"] = "segment-log/schema.lua",
    ["kong.plugins.segment-log.handler"] = "segment-log/handler.lua",
    ["kong.plugins.segment-log.jwt_parser"] = "segment-log/jwt_parser.lua"
  }
}
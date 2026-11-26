# basher install script and package metadata for shebang-mcp-sdk
# https://github.com/basherpm/basher
BINS="bin/shebang-mcp-sdk.sh:bin/mcp-sdk.sh:bin/script-runner:bin/script-runner.sh:bin/package-mcpb.sh"
DEPS=""

mkdir -p "${PREFIX:-${HOME}/.agents/shebang-mcp-sdk}" "${HOME}/.agents/skills"
cp -r plugin.json mcp.json server.json bin packaging skills io.github.sheldonrobinson.shebang-mcp-builder LICENSE README.md "${PREFIX:-${HOME}/.agents/shebang-mcp-sdk}/"
cp -r skills/shebang-mcp-builder "${HOME}/.agents/skills/"

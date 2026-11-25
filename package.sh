# basher install script for shebang-mcp-sdk
mkdir -p "${PREFIX:-${HOME}/.agents/shebang-mcp-sdk}" "${HOME}/.agents/skills"
cp -r plugin.json mcp.json server.json bin packaging skills io.github.sheldonrobinson.shebang-mcp-builder LICENSE README.md "${PREFIX:-${HOME}/.agents/shebang-mcp-sdk}/"
cp -r skills/shebang-mcp-sdk "${HOME}/.agents/skills/"


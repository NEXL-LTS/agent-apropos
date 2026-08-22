// TEMPORARY — U1/U9 spike probe. Deleted with .github/workflows/windows-spike.yml.
//
// Mirrors the generated OpenCode plugin's spawn call (an argument array, no
// shell) to answer whether Bun resolves an extensionless command name on
// Windows, which decides whether KTD8 needs a runtime fix.
async function probe(label, cmd) {
  try {
    const proc = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" })
    const text = await new Response(proc.stdout).text()
    await proc.exited
    console.log(`${label.padEnd(34)} OK  exit=${proc.exitCode} ${text.trim()}`)
  } catch (e) {
    console.log(`${label.padEnd(34)} FAIL  ${e.name}: ${e.message}`)
  }
}

await probe("extensionless name", ["agent-apropos", "--version"])
await probe("explicit .exe", ["agent-apropos.exe", "--version"])
await probe("absent name (control)", ["agent-apropos-absent-xyz", "--version"])

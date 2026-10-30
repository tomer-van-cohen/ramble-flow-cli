import Darwin
import RambleFlowCLI

setvbuf(stdout, nil, _IOLBF, 0)
exit(await CLI.main(CommandLine.arguments))

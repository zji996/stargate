package main

import (
	"fmt"
	"os"
)

func main() {
	var err error
	if len(os.Args) < 2 {
		err = fmt.Errorf("usage: stargate-remote server-init|serve|admin|enroll|sync|watch|transport|status [options]")
	} else {
		switch os.Args[1] {
		case "server-init":
			err = ServerInit(os.Args[2:])
		case "serve":
			err = Serve(os.Args[2:])
		case "check-server":
			err = CheckServer(os.Args[2:])
		case "prepare-server":
			err = PrepareServer(os.Args[2:])
		case "version":
			fmt.Printf("stargate-remote schema %d\n", SchemaVersion)
		case "admin":
			err = Admin(os.Args[2:])
		case "probe":
			err = Probe(os.Args[2:])
		case "enroll", "sync", "watch", "transport", "status", "prepare", "mapping-add", "mapping-delete", "service-publish", "service-delete", "grant-set", "binding-add", "binding-delete", "proxy-export":
			err = Agent(os.Args[1], os.Args[2:])
		default:
			err = fmt.Errorf("unknown command")
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "stargate-remote:", err)
		os.Exit(1)
	}
}

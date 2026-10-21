package main

import (
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"time"
)

func Probe(args []string) error {
	f := flag.NewFlagSet("probe", flag.ContinueOnError)
	address := f.String("address", "127.0.0.1:13389", "private or loopback RDP endpoint")
	if err := f.Parse(args); err != nil {
		return err
	}
	host, _, err := net.SplitHostPort(*address)
	if err != nil {
		return errors.New("invalid RDP endpoint")
	}
	ip := net.ParseIP(host)
	if ip == nil || (!ip.IsLoopback() && !ip.IsPrivate()) {
		return errors.New("RDP probe requires private or loopback IP")
	}
	c, err := net.DialTimeout("tcp", *address, 8*time.Second)
	if err != nil {
		return errors.New("RDP endpoint could not be reached")
	}
	defer c.Close()
	if err = c.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return err
	}
	request := []byte{3, 0, 0, 19, 14, 224, 0, 0, 0, 0, 0, 1, 0, 8, 0, 3, 0, 0, 0}
	if _, err = c.Write(request); err != nil {
		return errors.New("RDP negotiation write failed")
	}
	header := make([]byte, 4)
	if _, err = io.ReadFull(c, header); err != nil {
		return errors.New("RDP negotiation response missing")
	}
	size := int(binary.BigEndian.Uint16(header[2:]))
	if header[0] != 3 || header[1] != 0 || size < 19 || size > 4096 {
		return errors.New("invalid RDP response framing")
	}
	response := make([]byte, size-4)
	if _, err = io.ReadFull(c, response); err != nil {
		return errors.New("incomplete RDP response")
	}
	if response[1] != 0xd0 || response[7] != 2 || binary.LittleEndian.Uint16(response[9:11]) != 8 {
		return errors.New("RDP negotiation was rejected or returned an unsupported response")
	}
	fmt.Printf("RDP negotiation succeeded (%d bytes, selected protocol %d); desktop login is not tested\n", size, binary.LittleEndian.Uint32(response[11:15]))
	return nil
}

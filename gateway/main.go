// Gateway: the always-on front door for the Minecraft server.
//
// Players always connect to the gateway. When the main server is up, the gateway is a plain
// TCP proxy (game) and UDP relay (Simple Voice Chat). When it is down, the gateway answers
// server-list pings itself ("asleep - join to wake it up"), and on a join attempt it starts the
// main server's EC2 instance and tells the player to rejoin in about a minute.
//
// The main server shuts itself down when idle (see infra/files/idle-check.sh).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/aws/aws-sdk-go-v2/service/ec2/types"
)

type gateway struct {
	instanceID string
	backendTCP string       // main server's private IP:25565
	backendUDP *net.UDPAddr // main server's private IP:24454
	maxPlayers int
	ec2        *ec2.Client

	mu        sync.Mutex
	state     types.InstanceStateName
	wantStart bool // someone tried to join while the server was stopping; start it once stopped
}

func main() {
	g := &gateway{
		instanceID: mustEnv("BACKEND_INSTANCE_ID"),
		backendTCP: net.JoinHostPort(mustEnv("BACKEND_IP"), "25565"),
		maxPlayers: 15,
	}
	if n, err := strconv.Atoi(os.Getenv("MAX_PLAYERS")); err == nil {
		g.maxPlayers = n
	}
	var err error
	g.backendUDP, err = net.ResolveUDPAddr("udp", net.JoinHostPort(mustEnv("BACKEND_IP"), "24454"))
	if err != nil {
		log.Fatal(err)
	}
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatal(err)
	}
	g.ec2 = ec2.NewFromConfig(cfg)

	go g.pollState()
	go g.relayVoice(envOr("VOICE_LISTEN", ":24454"))

	ln, err := net.Listen("tcp", envOr("GAME_LISTEN", ":25565"))
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("gateway listening; backend %s (%s)", g.instanceID, g.backendTCP)
	for {
		c, err := ln.Accept()
		if err != nil {
			log.Print(err)
			continue
		}
		go g.handle(c)
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing env %s", k)
	}
	return v
}

// ---- EC2 state ----

func (g *gateway) pollState() {
	for {
		out, err := g.ec2.DescribeInstances(context.Background(), &ec2.DescribeInstancesInput{InstanceIds: []string{g.instanceID}})
		if err != nil {
			log.Printf("describe instance: %v", err)
		} else if len(out.Reservations) > 0 && len(out.Reservations[0].Instances) > 0 {
			s := out.Reservations[0].Instances[0].State.Name
			g.mu.Lock()
			if s != g.state {
				log.Printf("main server is %s", s)
			}
			g.state = s
			start := g.wantStart && s == types.InstanceStateNameStopped
			g.mu.Unlock()
			if start {
				g.start()
			}
		}
		time.Sleep(5 * time.Second)
	}
}

func (g *gateway) getState() types.InstanceStateName {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.state
}

func (g *gateway) start() {
	g.mu.Lock()
	g.wantStart = false
	g.mu.Unlock()
	log.Print("starting main server")
	if _, err := g.ec2.StartInstances(context.Background(), &ec2.StartInstancesInput{InstanceIds: []string{g.instanceID}}); err != nil {
		log.Printf("start instance: %v", err)
	}
}

// wake asks for the main server to start and returns the message to show the player.
func (g *gateway) wake() string {
	switch g.getState() {
	case types.InstanceStateNameStopped:
		g.start()
		return "Waking up the server!\n\nIt takes about a minute. Then join again."
	case types.InstanceStateNameStopping:
		g.mu.Lock()
		g.wantStart = true
		g.mu.Unlock()
		return "The server just went to sleep.\n\nIt will wake up again as soon as it finishes. Try again in about 2 minutes."
	case types.InstanceStateNamePending:
		return "The server is starting up.\n\nTry again in about a minute."
	case types.InstanceStateNameRunning:
		return "Almost ready - loading the world.\n\nTry again in a few seconds."
	default:
		return "The server is unavailable right now. Tell Samuel!"
	}
}

func (g *gateway) motd() string {
	switch g.getState() {
	case types.InstanceStateNameStopped:
		return "§7Friends SMP is asleep - §ajoin to wake it up"
	case types.InstanceStateNameStopping:
		return "§7Friends SMP is going to sleep..."
	default:
		return "§eFriends SMP is starting up..."
	}
}

// ---- TCP: proxy, or answer for a sleeping server ----

func (g *gateway) handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	br := bufio.NewReader(c)

	if b, err := br.Peek(1); err != nil || b[0] == 0xFE { // legacy (pre-1.7) ping: ignore
		return
	}
	raw, payload, err := readPacket(br, 1024)
	if err != nil {
		return
	}
	hs, err := parseHandshake(payload)
	if err != nil {
		return
	}

	if b, err := net.DialTimeout("tcp", g.backendTCP, 2*time.Second); err == nil {
		defer b.Close()
		c.SetDeadline(time.Time{})
		if _, err := b.Write(raw); err != nil {
			return
		}
		pipe(c, br, b)
		return
	}

	switch hs.nextState {
	case 1:
		g.serveStatus(c, br, hs.protocol)
	case 2, 3:
		msg := g.wake()
		log.Printf("join attempt from %s while server down", c.RemoteAddr())
		text, _ := json.Marshal(map[string]string{"text": msg})
		writePacket(c, 0x00, appendString(nil, string(text))) // Login Disconnect
		time.Sleep(250 * time.Millisecond)
	}
}

func (g *gateway) serveStatus(c net.Conn, br *bufio.Reader, protocol int32) {
	if _, _, err := readPacket(br, 64); err != nil { // Status Request
		return
	}
	status, _ := json.Marshal(map[string]any{
		"version":     map[string]any{"name": "Friends SMP", "protocol": protocol},
		"players":     map[string]any{"max": g.maxPlayers, "online": 0},
		"description": map[string]any{"text": g.motd()},
	})
	if writePacket(c, 0x00, appendString(nil, string(status))) != nil {
		return
	}
	if _, p, err := readPacket(br, 64); err == nil && len(p) == 9 && p[0] == 0x01 { // Ping -> Pong
		writePacket(c, 0x01, p[1:])
	}
}

func pipe(client net.Conn, clientReader io.Reader, backend net.Conn) {
	done := make(chan struct{}, 2)
	go func() { io.Copy(backend, clientReader); backend.(*net.TCPConn).CloseWrite(); done <- struct{}{} }()
	go func() { io.Copy(client, backend); client.(*net.TCPConn).CloseWrite(); done <- struct{}{} }()
	<-done
	<-done
}

// ---- UDP: Simple Voice Chat relay ----

func (g *gateway) relayVoice(addr string) {
	la, _ := net.ResolveUDPAddr("udp", addr)
	ln, err := net.ListenUDP("udp", la)
	if err != nil {
		log.Fatal(err)
	}
	type session struct {
		conn *net.UDPConn
		last time.Time
	}
	var mu sync.Mutex
	sessions := map[string]*session{}

	go func() { // close idle sessions
		for range time.Tick(30 * time.Second) {
			mu.Lock()
			for k, s := range sessions {
				if time.Since(s.last) > 2*time.Minute {
					s.conn.Close()
					delete(sessions, k)
				}
			}
			mu.Unlock()
		}
	}()

	buf := make([]byte, 65535)
	for {
		n, client, err := ln.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		mu.Lock()
		s, ok := sessions[client.String()]
		if !ok {
			if g.getState() != types.InstanceStateNameRunning {
				mu.Unlock()
				continue
			}
			conn, err := net.DialUDP("udp", nil, g.backendUDP)
			if err != nil {
				mu.Unlock()
				continue
			}
			s = &session{conn: conn}
			sessions[client.String()] = s
			go func(conn *net.UDPConn, client *net.UDPAddr) {
				b := make([]byte, 65535)
				for {
					n, err := conn.Read(b)
					if err != nil {
						if !errors.Is(err, net.ErrClosed) {
							mu.Lock()
							delete(sessions, client.String())
							mu.Unlock()
							conn.Close()
						}
						return
					}
					ln.WriteToUDP(b[:n], client)
				}
			}(conn, client)
		}
		s.last = time.Now()
		mu.Unlock()
		s.conn.Write(buf[:n])
	}
}

// ---- Minecraft protocol helpers ----

type handshake struct {
	protocol  int32
	nextState int32
}

func parseHandshake(p []byte) (handshake, error) {
	var hs handshake
	id, p, err := readVarInt(p)
	if err != nil || id != 0x00 {
		return hs, fmt.Errorf("not a handshake")
	}
	if hs.protocol, p, err = readVarInt(p); err != nil {
		return hs, err
	}
	strLen, p, err := readVarInt(p) // server address
	if err != nil || strLen < 0 || int(strLen)+2 > len(p) {
		return hs, fmt.Errorf("bad handshake")
	}
	p = p[strLen+2:] // skip address and port
	hs.nextState, _, err = readVarInt(p)
	return hs, err
}

// readPacket returns the raw bytes (length prefix included) and the payload.
func readPacket(r *bufio.Reader, max int) (raw, payload []byte, err error) {
	var length int32
	for i := 0; ; i++ {
		b, err := r.ReadByte()
		if err != nil {
			return nil, nil, err
		}
		raw = append(raw, b)
		length |= int32(b&0x7F) << (7 * i)
		if b&0x80 == 0 {
			break
		}
		if i >= 2 {
			return nil, nil, fmt.Errorf("varint too long")
		}
	}
	if length <= 0 || int(length) > max {
		return nil, nil, fmt.Errorf("bad packet length %d", length)
	}
	payload = make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, nil, err
	}
	return append(raw, payload...), payload, nil
}

func readVarInt(p []byte) (int32, []byte, error) {
	var v int32
	for i := 0; i < 5; i++ {
		if i >= len(p) {
			return 0, nil, io.ErrUnexpectedEOF
		}
		v |= int32(p[i]&0x7F) << (7 * i)
		if p[i]&0x80 == 0 {
			return v, p[i+1:], nil
		}
	}
	return 0, nil, fmt.Errorf("varint too long")
}

func appendVarInt(b []byte, v int32) []byte {
	u := uint32(v)
	for u >= 0x80 {
		b = append(b, byte(u)|0x80)
		u >>= 7
	}
	return append(b, byte(u))
}

func appendString(b []byte, s string) []byte {
	return append(appendVarInt(b, int32(len(s))), s...)
}

func writePacket(w io.Writer, id int32, data []byte) error {
	body := append(appendVarInt(nil, id), data...)
	_, err := w.Write(append(appendVarInt(nil, int32(len(body))), body...))
	return err
}

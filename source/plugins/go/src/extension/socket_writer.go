package extension

import (
	"net"
)

//MaxRetries for trying to write data to the socket
const MaxRetries = 5

//ReadBufferSize for reading data from sockets
//Current CI extension config size is ~5KB and going with 20KB to handle any future scenarios
const ReadBufferSize = 20480 

//FluentSocketWriter writes data to AMA's default fluent socket
type FluentSocketWriter struct {
	socket net.Conn
	sockAddress string 
}

func (fs *FluentSocketWriter) connect() error {
	c, err := net.Dial("unix", fs.sockAddress)
	if err != nil {
		return err
	}
	fs.socket = c
	return nil
}

func (fs *FluentSocketWriter) disConnect() error {
	if (fs.socket != nil) {
		fs.socket.Close()		
		fs.socket = nil
	}
	return nil
}

func (fs *FluentSocketWriter) writeWithRetries(data []byte) (int, error) {
	var (
		err error
		n   int
	)
	for i := 0; i < MaxRetries; i++ {
		n, err = fs.socket.Write(data)
		if err == nil {
			return n, nil
		}
	}
	if err, ok := err.(net.Error); !ok || !err.Temporary() {
		// so that connect() is called next time if write fails
		// this happens when mdsd is restarted
		_ = fs.socket.Close() // no need to log the socket closing error
		fs.socket = nil
	}
	return 0, err
}

func (fs *FluentSocketWriter) read() ([]byte, error) {
	buf := make([]byte, ReadBufferSize)
	n, err := fs.socket.Read(buf)
	if err != nil {
		return nil, err
	}
	return buf[:n], nil

}

func (fs *FluentSocketWriter) Write(payload []byte) (int, error) {
	if fs.socket == nil {
		// previous write failed with permanent error and socket was closed.
		if err := fs.connect(); err != nil {
			return 0, err
		}
	}

	return fs.writeWithRetries(payload)
}

//WriteAndRead writes data to the socket and sends the response back
func (fs *FluentSocketWriter) WriteAndRead(payload []byte) ([]byte, error) {
	_, err := fs.Write(payload)
	if err != nil {
		return nil, err
	}
	return fs.read()
}

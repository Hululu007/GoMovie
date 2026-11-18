package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"gomovie/native/core"
	"unsafe"
)

//export GoMovieRequest
func GoMovieRequest(input *C.char) *C.char {
	if input == nil {
		return C.CString(`{"ok":false,"error":"请求为空"}`)
	}
	return C.CString(core.NativeRequest(C.GoString(input)))
}

//export GoMovieFree
func GoMovieFree(value *C.char) { C.free(unsafe.Pointer(value)) }

func main() {}

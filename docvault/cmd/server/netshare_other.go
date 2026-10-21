//go:build !windows

package main

func connectStore(*Config) error { return nil }

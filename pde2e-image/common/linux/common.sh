#!/bin/bash

function hello() {
    echo "Hello from common linux script!"
    mkdir -p results
    echo "by bye" > results/goodbye.txt
}

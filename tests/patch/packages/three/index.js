#!/usr/bin/env node

import { ObjectId as ObjectIdOne } from 'one'
import { ObjectId as ObjectIdTwo } from 'two'

console.log(new ObjectIdOne() instanceof ObjectIdTwo)

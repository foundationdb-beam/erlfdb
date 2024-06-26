// Licensed under the Apache License, Version 2.0 (the "License"); you may not
// use this file except in compliance with the License. You may obtain a copy of
// the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
// License for the specific language governing permissions and limitations under
// the License.

#ifndef ERLFDB_FDB_H
#define ERLFDB_FDB_H

// FDB_LATEST_API_VERSION
#include <foundationdb/fdb_c_apiversion.g.h>

#ifndef FDB_API_VERSION
#define FDB_API_VERSION FDB_LATEST_API_VERSION
#endif // Allow command-line override of default FDB_API_VERSION

#include <foundationdb/fdb_c.h>

#endif // Included fdb.h

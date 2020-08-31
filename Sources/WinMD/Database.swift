/**
 * Copyright © 2020 Saleem Abdulrasool <compnerd@compnerd.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 *
 * 3. The name of the author may not be used to endorse or promote products
 *    derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **/

import WinSDK
import Foundation

public class Database {
  private init(data: Data) throws {
    let dos: DOSFile = DOSFile(data: data)
    try dos.validate()

    let pe: PEFile = PEFile(from: dos)
    try pe.validate()

    let cor20: COR20File = try COR20File(from: pe)
    try cor20.validate()

    switch cor20.Metadata {
    case .failure(let error):
      throw error
    case .success(let metadata):
      let metadata: COR20Metadata = COR20Metadata(parsing: metadata)
      guard metadata.Signature == COR20_METADATA_SIGNATURE else {
        throw WinMDError.invalidCLRSignature
      }
    }
  }

  public convenience init(at path: URL) throws {
    let buffer: Data = try NSData(contentsOf: path, options: .alwaysMapped) as Data
    try self.init(data: buffer)
  }

  public convenience init(atPath path: String) throws {
    try self.init(at: URL(fileURLWithPath: path))
  }
}

# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::SpriteFS do
  let(:client) { Sprites::Client.new("test-token", base_url: "http://localhost:8080") }
  let(:filesystem) { client.sprite("demo/name").filesystem_at("/app") }
  let(:base) { "http://localhost:8080/v1/sprites/demo%2Fname/fs" }

  after { client.close }

  it "supports the complete REST filesystem surface with official wire names" do
    stub_request(:get, "#{base}/read?path=file.txt&workingDir=%2Fapp")
      .to_return(status: 200, body: "hello")
    stub_request(
      :put,
      "#{base}/write?mkdirParents=true&mode=0600&path=file.txt&workingDir=%2Fapp"
    ).to_return(status: 200)
    stub_request(
      :get,
      "#{base}/list?path=.&pattern=*.rb&recursive=true&workingDir=%2Fapp"
    ).to_return(
      status: 200,
      body: JSON.generate(
        entries: [
          {
            name: "file.txt", path: "/app/file.txt", type: "file", size: 5,
            mode: "0644", modTime: "2026-07-20T10:00:00Z", isDir: false
          }
        ]
      )
    )
    stub_request(:get, "#{base}/list?path=file.txt&workingDir=%2Fapp")
      .to_return(
        status: 200,
        body: JSON.generate(
          entries: [
            {
              name: "file.txt", path: "/app/file.txt", type: "file", size: 5,
              mode: "0644", modTime: "2026-07-20T10:00:00Z", isDir: false
            }
          ]
        )
      )
    stub_request(
      :put,
      "#{base}/write?mkdirParents=true&mode=0755&path=nested%2Fpath%2F.keep&workingDir=%2Fapp"
    ).to_return(status: 200)
    stub_request(:delete, %r{#{Regexp.escape(base)}/delete\?.*path=old})
      .to_return(status: 204)
    stub_request(:post, "#{base}/rename").to_return(status: 200)
    stub_request(:post, "#{base}/copy").to_return(status: 200)
    stub_request(:post, "#{base}/chmod").to_return(status: 200)
    stub_request(:post, "#{base}/chown").to_return(status: 200)

    expect(filesystem.read_file("file.txt")).to eq("hello")
    filesystem.write_file("file.txt", "data", mode: 0o600)
    expect(
      a_request(:put, "#{base}/write?mkdirParents=true&mode=0600&path=file.txt&workingDir=%2Fapp")
        .with(body: "data")
    ).to have_been_made.once
    expect(filesystem.read_dir(".", recursive: true, pattern: "*.rb").map(&:name)).to eq(["file.txt"])
    entry = filesystem.stat("file.txt")
    expect(entry).to be_file
    expect(entry).not_to be_dir
    expect(entry.mode_value).to eq(0o644)
    expect(filesystem.exists?("file.txt")).to be true
    filesystem.mkdir("nested/path", recursive: true)
    filesystem.remove("old", recursive: true, as_root: true)
    filesystem.rename("old", "new", as_root: true)
    filesystem.copy("source", "dest", recursive: true, preserve_attrs: true, as_root: true)
    filesystem.chmod("script.sh", 0o755, recursive: true, as_root: true)
    filesystem.chown("script.sh", uid: "sprite", gid: 1000, recursive: true, as_root: true)

    expect(a_request(:post, "#{base}/rename").with { |wire|
      JSON.parse(wire.body) == {
        "source" => "old", "dest" => "new", "workingDir" => "/app", "asRoot" => true
      }
    }).to have_been_made.once
    expect(a_request(:post, "#{base}/copy").with { |wire|
      JSON.parse(wire.body) == {
        "source" => "source", "dest" => "dest", "workingDir" => "/app",
        "recursive" => true, "preserveAttrs" => true, "asRoot" => true
      }
    }).to have_been_made.once
    expect(a_request(:post, "#{base}/chmod").with { |wire|
      JSON.parse(wire.body).slice("mode", "recursive", "asRoot") == {
        "mode" => "0755", "recursive" => true, "asRoot" => true
      }
    }).to have_been_made.once
    expect(a_request(:post, "#{base}/chown").with { |wire|
      JSON.parse(wire.body).slice("uid", "gid", "recursive", "asRoot") == {
        "uid" => "sprite", "gid" => 1000, "recursive" => true, "asRoot" => true
      }
    }).to have_been_made.once
  end

  it "supports exists, force remove, append, and JSON helpers without losing typed errors" do
    stub_request(:get, "#{base}/list?path=missing&workingDir=%2Fapp")
      .to_return(
        status: 404,
        body: JSON.generate(error: "not found", code: "ENOENT", path: "/app/missing")
      )
    stub_request(:delete, "#{base}/delete?path=missing&workingDir=%2Fapp")
      .to_return(status: 404, body: JSON.generate(error: "not found", code: "ENOENT"))
    stub_request(:get, "#{base}/read?path=notes.txt&workingDir=%2Fapp")
      .to_return(status: 200, body: "hello")
    stub_request(
      :put,
      "#{base}/write?mkdirParents=true&mode=0644&path=notes.txt&workingDir=%2Fapp"
    ).to_return(status: 200)
    stub_request(:get, "#{base}/read?path=data.json&workingDir=%2Fapp")
      .to_return(status: 200, body: "{\"ok\":true}")
    stub_request(
      :put,
      "#{base}/write?mkdirParents=true&mode=0644&path=data.json&workingDir=%2Fapp"
    ).to_return(status: 200)

    expect(filesystem.exists?("missing")).to be false
    expect { filesystem.stat("missing") }.to raise_error(Sprites::FSNotFoundError) { |error|
      expect(error.code).to eq("ENOENT")
      expect(error.path).to eq("/app/missing")
      expect(error.status_code).to eq(404)
    }
    expect { filesystem.remove("missing", force: true) }.not_to raise_error
    filesystem.append_file("notes.txt", " world")
    expect(
      a_request(:put, "#{base}/write?mkdirParents=true&mode=0644&path=notes.txt&workingDir=%2Fapp")
        .with(body: "hello world")
    ).to have_been_made.once
    expect(filesystem.read_json("data.json")).to eq("ok" => true)
    filesystem.write_json("data.json", { ok: true }, spaces: 2)
    expect(a_request(
      :put,
      "#{base}/write?mkdirParents=true&mode=0644&path=data.json&workingDir=%2Fapp"
    ).with { |wire|
      wire.body.include?("\n") && JSON.parse(wire.body) == { "ok" => true }
    }).to have_been_made.once
    expect { filesystem.chown("file") }.to raise_error(ArgumentError, /uid or gid/)
  end
end

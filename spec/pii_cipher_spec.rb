# frozen_string_literal: true

RSpec.describe PiiCipher do
  it "has a version number" do
    expect(PiiCipher::VERSION).not_to be nil
  end

  it "can call into Rust" do
    result = PiiCipher.hello("world")

    expect(result).to be("Hello earth, from Rust!")
  end
end

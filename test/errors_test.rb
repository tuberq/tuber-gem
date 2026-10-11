# frozen_string_literal: true

# test/errors_test.rb

require File.expand_path('../test_helper', __FILE__)

describe "Tuber::Errors" do
  it 'should raise proper exception for invalid status NOT_FOUND' do
    @klazz = Tuber::UnexpectedResponse.from_status("NOT_FOUND", "job-stats -1")
    assert_kind_of(Tuber::NotFoundError, @klazz)
    assert_equal 'job-stats -1', @klazz.cmd
    assert_equal 'NOT_FOUND', @klazz.status
  end

  it 'should raise proper exception for invalid status BAD_FORMAT' do
    @klazz = Tuber::UnexpectedResponse.from_status("BAD_FORMAT", "FAKE")
    assert_kind_of(Tuber::BadFormatError, @klazz)
    assert_equal 'FAKE', @klazz.cmd
    assert_equal 'BAD_FORMAT', @klazz.status
  end

  it 'should raise proper exception for invalid status DEADLINE_SOON' do
    @klazz = Tuber::UnexpectedResponse.from_status("DEADLINE_SOON", "reserve 0")
    assert_kind_of(Tuber::DeadlineSoonError, @klazz)
    assert_equal 'reserve 0', @klazz.cmd
    assert_equal 'DEADLINE_SOON', @klazz.status
  end

  it 'should raise proper exception for invalid status EXPECTED_CRLF' do
    @klazz = Tuber::UnexpectedResponse.from_status("EXPECTED_CRLF", "reserve 0")
    assert_kind_of(Tuber::ExpectedCrlfError, @klazz)
    assert_equal 'reserve 0', @klazz.cmd
    assert_equal 'EXPECTED_CRLF', @klazz.status
  end

  it 'should raise proper exception for invalid status OUT_OF_STORAGE' do
    @klazz = Tuber::UnexpectedResponse.from_status("OUT_OF_STORAGE", "put 0 0 120 4")
    assert_kind_of(Tuber::UnexpectedResponse, @klazz)
    assert_equal 'OutOfStorageError', @klazz.class.name.split('::').last
    assert_equal 'OUT_OF_STORAGE', @klazz.status
  end
end
